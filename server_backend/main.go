// Command morse-relay is a minimal, content-blind message relay for Morse
// Messenger clients.
//
// The relay never sees plaintext: it only ever handles opaque, already
// end-to-end-encrypted payloads keyed by client-supplied identity strings
// (raw RSA public keys). Its job is entirely about connection lifecycle and
// store-and-forward delivery, not content.
//
// Security/reliability properties this file intentionally provides:
//   - Every untrusted input (packet size, identity length, queue depth) is
//     bounded, so a single misbehaving or malicious client can't exhaust
//     server memory or crash the process.
//   - Per-connection registration is rate limited per remote IP.
//   - Offline-message queues are capped and expire, instead of growing
//     without bound for identities that never reconnect.
//   - Presence broadcast never holds the shared lock while performing
//     network I/O, so one slow/stalled client can't stall registration or
//     delivery for everyone else.
//   - Optional TLS support, because this relay carries traffic for an
//     anonymity/security-focused application and should not be run as
//     plaintext ws:// over the open Internet if it can be avoided.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

// --- wire format -----------------------------------------------------------

// Packet mirrors the client-side Packet model. The relay only inspects
// Type/FromUser/ToUser for routing; Payload is opaque ciphertext as far as
// the server is concerned.
type Packet struct {
	Type     string `json:"type"`
	FromUser string `json:"fromUser"`
	ToUser   string `json:"toUser"`
	Payload  string `json:"payload"`
}

const (
	packetTypeRegister     = "register"
	packetTypeMessage      = "message"
	packetTypeStatusUpdate = "status_update"
)

// --- bounds ------------------------------------------------------------

const (
	// maxIdentityLength bounds fromUser/toUser. Must stay comfortably above
	// any real RSA public key's serialized length.
	maxIdentityLength = 4096

	// maxPayloadBytes bounds a single packet's payload. Generous enough for
	// hybrid-encrypted chat messages with a modest file attachment.
	maxPayloadBytes = 12 * 1024 * 1024

	// maxQueuedPerUser caps how many packets we'll hold for an identity
	// that isn't currently connected, so an identity that never reconnects
	// (or never existed) can't be used to grow server memory without bound.
	maxQueuedPerUser = 200

	// offlineMessageTTL bounds how long a queued packet is held before
	// being dropped, so long-abandoned identities don't accumulate memory
	// forever.
	offlineMessageTTL = 72 * time.Hour

	// registrationsPerIPWindow / maxRegistrationsPerIP throttle how fast a
	// single remote address can open new connections, as a cheap defense
	// against connection-flood abuse.
	registrationsPerIPWindow = time.Minute
	maxRegistrationsPerIP    = 30
)

const (
	writeWait  = 10 * time.Second
	pongWait   = 60 * time.Second
	pingPeriod = (pongWait * 9) / 10
)

// --- offline queue -----------------------------------------------------

type queuedPacket struct {
	packet   Packet
	queuedAt time.Time
}

// --- hub -----------------------------------------------------------------

// hub owns all shared server state. Wrapping it in a struct (instead of
// package-level globals, as the previous version used) makes the
// concurrency contract explicit and the code unit-testable.
type hub struct {
	mu      sync.RWMutex
	clients map[string]*websocket.Conn
	queue   map[string][]queuedPacket

	rateMu      sync.Mutex
	regAttempts map[string][]time.Time // remote IP -> recent registration timestamps
}

func newHub() *hub {
	return &hub{
		clients:     make(map[string]*websocket.Conn),
		queue:       make(map[string][]queuedPacket),
		regAttempts: make(map[string][]time.Time),
	}
}

// allowRegistration applies a simple sliding-window rate limit per remote
// IP so a single source can't spin up unbounded connections.
func (h *hub) allowRegistration(remoteIP string) bool {
	h.rateMu.Lock()
	defer h.rateMu.Unlock()

	now := time.Now()
	cutoff := now.Add(-registrationsPerIPWindow)

	attempts := h.regAttempts[remoteIP]
	kept := attempts[:0]
	for _, t := range attempts {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}

	if len(kept) >= maxRegistrationsPerIP {
		h.regAttempts[remoteIP] = kept
		return false
	}

	kept = append(kept, now)
	h.regAttempts[remoteIP] = kept
	return true
}

// broadcastStatus notifies every other connected client that identity
// senderKey's online status changed.
//
// Deliberately snapshots the connection list under the lock, then performs
// all network writes *after* releasing it. The previous implementation
// held an RLock for the entire broadcast loop; a single slow/stalled peer
// could therefore delay every other goroutine waiting on the mutex
// (including new registrations and message delivery) for the full write
// timeout.
func (h *hub) broadcastStatus(senderKey string, online bool) {
	statusPayload := "offline"
	if online {
		statusPayload = "online"
	}
	packetBytes, err := json.Marshal(Packet{
		Type:     packetTypeStatusUpdate,
		FromUser: senderKey,
		ToUser:   "",
		Payload:  statusPayload,
	})
	if err != nil {
		return
	}

	h.mu.RLock()
	targets := make([]*websocket.Conn, 0, len(h.clients))
	for k, conn := range h.clients {
		if k != senderKey {
			targets = append(targets, conn)
		}
	}
	h.mu.RUnlock()

	for _, conn := range targets {
		_ = conn.SetWriteDeadline(time.Now().Add(writeWait))
		_ = conn.WriteMessage(websocket.TextMessage, packetBytes)
	}
}

// enqueueOffline stores a packet for an identity that isn't currently
// connected, respecting the per-user cap (oldest dropped first) so this
// can't be used to exhaust memory.
func (h *hub) enqueueOffline(target string, p Packet) {
	h.mu.Lock()
	defer h.mu.Unlock()

	q := h.queue[target]
	if len(q) >= maxQueuedPerUser {
		q = q[1:] // drop oldest
	}
	q = append(q, queuedPacket{packet: p, queuedAt: time.Now()})
	h.queue[target] = q
}

// drainOffline returns and clears any queued packets for an identity,
// discarding any that have exceeded offlineMessageTTL.
func (h *hub) drainOffline(target string) []Packet {
	h.mu.Lock()
	queued, exists := h.queue[target]
	if exists {
		delete(h.queue, target)
	}
	h.mu.Unlock()

	if !exists {
		return nil
	}

	cutoff := time.Now().Add(-offlineMessageTTL)
	fresh := make([]Packet, 0, len(queued))
	for _, qp := range queued {
		if qp.queuedAt.After(cutoff) {
			fresh = append(fresh, qp.packet)
		}
	}
	return fresh
}

// pruneExpiredQueues periodically drops stale queued messages for
// identities that never reconnect, so abandoned queues don't accumulate
// forever. Run as a background goroutine.
func (h *hub) pruneExpiredQueues(ctx context.Context) {
	ticker := time.NewTicker(1 * time.Hour)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cutoff := time.Now().Add(-offlineMessageTTL)
			h.mu.Lock()
			for id, queued := range h.queue {
				fresh := queued[:0]
				for _, qp := range queued {
					if qp.queuedAt.After(cutoff) {
						fresh = append(fresh, qp)
					}
				}
				if len(fresh) == 0 {
					delete(h.queue, id)
				} else {
					h.queue[id] = fresh
				}
			}
			h.mu.Unlock()
		}
	}
}

// --- connection handling -------------------------------------------------

var upgrader = websocket.Upgrader{
	HandshakeTimeout: 10 * time.Second,
	// This relay carries no cookies/session auth and authenticates nothing
	// at the transport layer - identity and message authenticity are
	// handled end-to-end by the clients themselves (RSA signatures over
	// every payload). Accepting any Origin is therefore not a CSRF-style
	// risk in the traditional sense, but it does mean any web page could
	// direct a visitor's browser to open connections against this relay.
	// If you're running this publicly, consider restricting this to known
	// origins.
	CheckOrigin: func(r *http.Request) bool { return true },
}

func safePrefix(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

func (h *hub) handleConnections(w http.ResponseWriter, r *http.Request) {
	remoteIP := r.RemoteAddr
	if !h.allowRegistration(remoteIP) {
		http.Error(w, "too many connection attempts, slow down", http.StatusTooManyRequests)
		return
	}

	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}

	var userIdentity string

	_ = ws.SetReadDeadline(time.Now().Add(pongWait))
	ws.SetPongHandler(func(string) error {
		_ = ws.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})
	// Prevent a single client from sending an unbounded frame and forcing
	// the server to buffer it entirely in memory.
	ws.SetReadLimit(maxPayloadBytes + 8192)

	stopHeartbeat := make(chan struct{})
	go func(c *websocket.Conn) {
		ticker := time.NewTicker(pingPeriod)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				_ = c.SetWriteDeadline(time.Now().Add(writeWait))
				if err := c.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}
			case <-stopHeartbeat:
				return
			}
		}
	}(ws)

	defer func() {
		close(stopHeartbeat)
		_ = ws.Close()

		if userIdentity == "" {
			return
		}

		h.mu.Lock()
		activeConn, exists := h.clients[userIdentity]
		if exists && activeConn == ws {
			delete(h.clients, userIdentity)
		} else {
			exists = false
		}
		h.mu.Unlock()

		if exists {
			h.broadcastStatus(userIdentity, false)
			log.Printf("connection closed: %s...", safePrefix(userIdentity, 15))
		}
	}()

	for {
		_, message, err := ws.ReadMessage()
		if err != nil {
			break
		}

		if len(message) > maxPayloadBytes {
			log.Printf("dropping oversized packet (%d bytes) from %s...", len(message), safePrefix(userIdentity, 15))
			continue
		}

		var p Packet
		if err := json.Unmarshal(message, &p); err != nil {
			continue
		}

		if !validPacket(p) {
			continue
		}

		switch p.Type {
		case packetTypeRegister:
			h.handleRegister(ws, &userIdentity, p)
		case packetTypeMessage:
			h.handleMessage(p)
		}
	}
}

// validPacket applies the same bounds the client enforces, so a malformed
// or hostile packet is rejected before it ever touches shared state.
func validPacket(p Packet) bool {
	from := strings.TrimSpace(p.FromUser)
	to := strings.TrimSpace(p.ToUser)

	if from == "" || len(from) > maxIdentityLength {
		return false
	}
	if p.Type == packetTypeMessage && (to == "" || len(to) > maxIdentityLength) {
		return false
	}
	if len(p.Payload) > maxPayloadBytes {
		return false
	}
	return true
}

func (h *hub) handleRegister(ws *websocket.Conn, userIdentity *string, p Packet) {
	identity := strings.TrimSpace(p.FromUser)
	if identity == "" {
		return
	}
	*userIdentity = identity

	h.mu.Lock()
	if oldConn, exists := h.clients[identity]; exists {
		// A second connection registered under the same identity. Since
		// the relay does not (and currently cannot cheaply) verify that a
		// registrant actually holds the private key for the identity it
		// claims, this could be a legitimate reconnect from the same user
		// or a collision with someone else claiming the same public
		// identity string. Either way, message *content* stays protected
		// by end-to-end RSA/AES-GCM + signatures regardless of who holds
		// the socket - the worst case here is a denial-of-service against
		// that identity's connection, not a confidentiality break.
		_ = oldConn.Close()
	}
	h.clients[identity] = ws

	onlineUsers := make([]string, 0, len(h.clients))
	for k := range h.clients {
		if k != identity {
			onlineUsers = append(onlineUsers, k)
		}
	}
	h.mu.Unlock()

	pending := h.drainOffline(identity)
	if len(pending) > 0 {
		go func(pkts []Packet, targetWs *websocket.Conn) {
			for _, pkt := range pkts {
				packetBytes, err := json.Marshal(pkt)
				if err != nil {
					continue
				}
				_ = targetWs.SetWriteDeadline(time.Now().Add(writeWait))
				if err := targetWs.WriteMessage(websocket.TextMessage, packetBytes); err != nil {
					return
				}
			}
		}(pending, ws)
	}

	onlineListBytes, err := json.Marshal(onlineUsers)
	if err == nil {
		initialStatusPacket := Packet{
			Type:     packetTypeStatusUpdate,
			FromUser: "server",
			ToUser:   identity,
			Payload:  string(onlineListBytes),
		}
		if initialBytes, err := json.Marshal(initialStatusPacket); err == nil {
			_ = ws.SetWriteDeadline(time.Now().Add(writeWait))
			_ = ws.WriteMessage(websocket.TextMessage, initialBytes)
		}
	}

	go h.broadcastStatus(identity, true)
	log.Printf("registered: %s...", safePrefix(identity, 15))
}

func (h *hub) handleMessage(p Packet) {
	target := strings.TrimSpace(p.ToUser)

	h.mu.RLock()
	recipientConn, found := h.clients[target]
	h.mu.RUnlock()

	if !found {
		h.enqueueOffline(target, p)
		return
	}

	packetBytes, err := json.Marshal(p)
	if err != nil {
		return
	}
	_ = recipientConn.SetWriteDeadline(time.Now().Add(writeWait))
	if err := recipientConn.WriteMessage(websocket.TextMessage, packetBytes); err != nil {
		// Delivery failed (peer likely disconnecting) - let that
		// connection's own read loop discover the error and clean up;
		// queue the message so it isn't silently lost.
		h.enqueueOffline(target, p)
	}
}

// --- entrypoint ------------------------------------------------------------

func main() {
	addr := flag.String("addr", envOr("MORSE_RELAY_ADDR", ":8080"), "listen address")
	tlsCert := flag.String("tls-cert", os.Getenv("MORSE_RELAY_TLS_CERT"), "path to TLS certificate (optional)")
	tlsKey := flag.String("tls-key", os.Getenv("MORSE_RELAY_TLS_KEY"), "path to TLS private key (optional)")
	flag.Parse()

	h := newHub()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go h.pruneExpiredQueues(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", h.handleConnections)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	server := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	useTLS := *tlsCert != "" && *tlsKey != ""
	if useTLS {
		server.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	}

	go func() {
		var err error
		if useTLS {
			log.Printf("relay listening on %s (TLS)", *addr)
			err = server.ListenAndServeTLS(*tlsCert, *tlsKey)
		} else {
			log.Printf("relay listening on %s (plaintext - consider TLS for real deployments)", *addr)
			err = server.ListenAndServe()
		}
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server failure: %v", err)
		}
	}()

	// Graceful shutdown on SIGINT/SIGTERM so in-flight connections get a
	// chance to close cleanly instead of being killed mid-write.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	log.Println("shutting down...")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	_ = server.Shutdown(shutdownCtx)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
