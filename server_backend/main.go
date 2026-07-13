package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type Packet struct {
	Type     string `json:"type"`     // "register", "message", "status_update", "pong"
	FromUser string `json:"fromUser"` // Sender's raw public key
	ToUser   string `json:"toUser"`   // Recipient's raw public key
	Payload  string `json:"payload"`  // Ciphertext or metadata payload
}

// Thread-safe map tracking active client sockets
var (
	clients      = make(map[string]*websocket.Conn)
	offlineQueue = make(map[string][]Packet)
	stateMutex   sync.RWMutex // Upgraded to RWMutex for high concurrent read efficiency
)

// Global WebSocket Upgrader parameters
var upgrader = websocket.Upgrader{
	HandshakeTimeout: 10 * time.Second,
	CheckOrigin:      func(r *http.Request) bool { return true },
}

const (
	// Time allowed to write a message to the peer.
	writeWait = 10 * time.Second
	// Time allowed to read the next pong message from the peer.
	pongWait = 60 * time.Second
	// Send pings to peer with this period. Must be less than pongWait.
	pingPeriod = (pongWait * 9) / 10
)

// Thread-safe status broadcast engine
func broadcastStatus(senderKey string, online bool) {
	statusPayload := "offline"
	if online {
		statusPayload = "online"
	}
	updatePacket := Packet{
		Type:     "status_update",
		FromUser: senderKey,
		ToUser:   "",
		Payload:  statusPayload,
	}
	packetBytes, err := json.Marshal(updatePacket)
	if err != nil {
		return
	}

	stateMutex.RLock() // Protect iteration over shared clients map
	defer stateMutex.RUnlock()

	for k, conn := range clients {
		if k != senderKey {
			_ = conn.SetWriteDeadline(time.Now().add(writeWait))
			_ = conn.WriteMessage(websocket.TextMessage, packetBytes)
		}
	}
}

func handleConnections(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}

	var userIdentity string
	
	// Configure application-level timeouts for the socket connection
	_ = ws.SetReadDeadline(time.Now().add(pongWait))
	ws.SetPongHandler(func(string) error {
		_ = ws.SetReadDeadline(time.Now().add(pongWait))
		return nil
	})

	// Spawn a background heartbeater specialized for this client
	stopHeartbeat := make(chan struct{})
	go func(c *websocket.Conn) {
		ticker := time.NewTicker(pingPeriod)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				_ = c.SetWriteDeadline(time.Now().add(writeWait))
				if err := c.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}
			case <-stopHeartbeat:
				return
			}
		}
	}(ws)

	// Clean up registration records gracefully on pipeline severance
	defer func() {
		close(stopHeartbeat)
		_ = ws.Close()

		if userIdentity != "" {
			stateMutex.Lock()
			// Ensure we only delete the entry if it matches this specific connection instance
			if activeConn, exists := clients[userIdentity]; exists && activeConn == ws {
				delete(clients, userIdentity)
				stateMutex.Unlock()
				broadcastStatus(userIdentity, false)
				fmt.Printf("Node connection cleaned up: [%s...]\n", userIdentity[:15])
			} else {
				stateMutex.Unlock()
			}
		}
	}()

	for {
		_, message, err := ws.ReadMessage()
		if err != nil {
			break // Triggers deferred connection teardown
		}

		var p Packet
		if err := json.Unmarshal(message, &p); err != nil {
			continue
		}

		switch p.Type {
		case "register":
			userIdentity = strings.TrimSpace(p.FromUser)
			if userIdentity == "" {
				return
			}

			stateMutex.Lock()
			// If a ghost socket is present, close it to free up resources
			if oldConn, exists := clients[userIdentity]; exists {
				_ = oldConn.Close()
			}
			clients[userIdentity] = ws

			// Aggregate active contacts safely using read-only access characteristics
			onlineUsers := make([]string, 0)
			for k := range clients {
				if k != userIdentity {
					onlineUsers = append(onlineUsers, k)
				}
			}

			// Capture offline messages cleanly to prevent lock contention while handling network output
			var pendingPackets []Packet
			if queued, hasPending := offlineQueue[userIdentity]; hasPending {
				pendingPackets = queued
				delete(offlineQueue, userIdentity)
			}
			stateMutex.Unlock()

			// Dispatch cached historical offline payloads asynchronously
			if len(pendingPackets) > 0 {
				go func(pkts []Packet, targetWs *websocket.Conn) {
					for _, pkt := range pkts {
						packetBytes, err := json.Marshal(pkt)
						if err == nil {
							_ = targetWs.SetWriteDeadline(time.Now().add(writeWait))
							_ = targetWs.WriteMessage(websocket.TextMessage, packetBytes)
						}
					}
				}(pendingPackets, ws)
			}

			// Push roster lists down the network stream
			onlineListBytes, _ := json.Marshal(onlineUsers)
			initialStatusPacket := Packet{
				Type:     "status_update",
				FromUser: "server",
				ToUser:   userIdentity,
				Payload:  string(onlineListBytes),
			}
			if initialBytes, err := json.Marshal(initialStatusPacket); err == nil {
				_ = ws.SetWriteDeadline(time.Now().add(writeWait))
				_ = ws.WriteMessage(websocket.TextMessage, initialBytes)
			}

			// Broadcast presence notifications across the system
			go broadcastStatus(userIdentity, true)
			fmt.Printf("Registered Connection Pipeline for: [%s...]\n", userIdentity[:15])

		case "message":
			targetUser := strings.TrimSpace(p.ToUser)
			stateMutex.Lock()
			recipientConn, found := clients[targetUser]

			if found {
				stateMutex.Unlock()
				packetBytes, err := json.Marshal(p)
				if err == nil {
					_ = recipientConn.SetWriteDeadline(time.Now().add(writeWait))
					// If the write fails, let the client's heartbeat worker handle cleanup
					_ = recipientConn.WriteMessage(websocket.TextMessage, packetBytes)
				}
			} else {
				offlineQueue[targetUser] = append(offlineQueue[targetUser], p)
				stateMutex.Unlock()
			}
		}
	}
}

func main() {
	http.HandleFunc("/ws", handleConnections)
	fmt.Println("Secure Server running on :8080")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		fmt.Printf("Server failure: %v\n", err)
	}
}