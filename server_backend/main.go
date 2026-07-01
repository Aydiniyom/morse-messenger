package main

import (
    "encoding/json"
    "fmt"
    "net/http"
    "strings"
    "sync"

    "github.com/gorilla/websocket"
)

type Packet struct {
    Type     string `json:"type"`     // "register" or "message"
    FromUser string `json:"fromUser"` // sender's full Raw Public Key
    ToUser   string `json:"toUser"`   // recipient's full Raw Public Key
    Payload  string `json:"payload"`  // ciphertext payload
}

var clients = make(map[string]*websocket.Conn)

// --- ADDED: Store-and-forward queue for offline packets ---
var offlineQueue = make(map[string][]Packet)

var mutex = &sync.Mutex{}
var upgrader = websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}

func handleConnections(w http.ResponseWriter, r *http.Request) {
    ws, err := upgrader.Upgrade(w, r, nil)
    if err != nil {
        return
    }
    defer ws.Close()

    var userIdentity string

    for {
        _, message, err := ws.ReadMessage()
        if err != nil {
            if userIdentity != "" {
                mutex.Lock()
                delete(clients, userIdentity)
                mutex.Unlock()
                // Use a safe substring check in case the string is unexpectedly short
                displayLen := 15
                if len(userIdentity) < displayLen {
                    displayLen = len(userIdentity)
                }
                fmt.Printf("Node disconnected: [%s...]\n", userIdentity[:displayLen])
            }
            break
        }

        var p Packet
        if err := json.Unmarshal(message, &p); err != nil {
            continue
        }

        switch p.Type {
        case "register":
            userIdentity = strings.TrimSpace(p.FromUser) // clean registration key
            
            mutex.Lock()
            clients[userIdentity] = ws
            
            // --- FLOATING PACKET FLUSH ---
            // Check if there are any cached messages waiting for this newly registered user
            pendingPackets, hashPending := offlineQueue[userIdentity]
            if hashPending {
                fmt.Printf("Flushing %d cached offline messages for: [%s...]\n", len(pendingPackets), userIdentity[:15])
                for _, queuedPacket := range pendingPackets {
                    packetBytes, _ := json.Marshal(queuedPacket)
                    ws.WriteMessage(websocket.TextMessage, packetBytes)
                }
                // Clear the cache for this user now that they are safely delivered
                delete(offlineQueue, userIdentity)
            }
            mutex.Unlock()
            
            displayLen := 25
            if len(userIdentity) < displayLen {
                displayLen = len(userIdentity)
            }
            fmt.Printf("Registered Connection Pipeline for Public Key: [%s...]\n", userIdentity[:displayLen])

        case "message":
            targetUser := strings.TrimSpace(p.ToUser) // clean routing key
            mutex.Lock()
            recipientConn, found := clients[targetUser]

            if found {
                // Target client is online; route it instantly
                mutex.Unlock()
                packetBytes, _ := json.Marshal(p)
                recipientConn.WriteMessage(websocket.TextMessage, packetBytes)
                fmt.Printf("Routed pure p2p packet directly to: [%s...]\n", targetUser[:15])
            } else {
                // Target client is offline; catch it in our floating cache array
                offlineQueue[targetUser] = append(offlineQueue[targetUser], p)
                mutex.Unlock()
                fmt.Printf("Target node [%s...] is offline. Saved packet to storage queue.\n", targetUser[:15])
            }
        }
    }
}

func main() {
    http.HandleFunc("/ws", handleConnections)
    fmt.Println("Server running on :8080")
    http.ListenAndServe(":8080", nil)
}