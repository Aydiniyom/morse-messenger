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

// --- Store-and-forward queue for offline packets ---
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

    // Helper to broadcast status changes to everyone else
    broadcastStatus := func(user string, online bool) {
        statusPayload := "offline"
        if online {
            statusPayload = "online"
        }
        updatePacket := Packet{
            Type:     "status_update",
            FromUser: user,
            ToUser:   "",
            Payload:  statusPayload,
        }
        packetBytes, _ := json.Marshal(updatePacket)

        mutex.Lock()
        for k, conn := range clients {
            if k != user { // Don't send it back to themselves
                conn.WriteMessage(websocket.TextMessage, packetBytes)
            }
        }
        mutex.Unlock()
    }

    for {
        _, message, err := ws.ReadMessage()
        if err != nil {
            if userIdentity != "" {
                mutex.Lock()
                delete(clients, userIdentity)
                mutex.Unlock()
                
                // --- BROADCAST OFFLINE STATUS ---
                broadcastStatus(userIdentity, false)

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
            userIdentity = strings.TrimSpace(p.FromUser)
            
            mutex.Lock()
            clients[userIdentity] = ws
            
            // Collect currently online public keys to send to the newcomer
            onlineUsers := []string{}
            for k := range clients {
                if k != userIdentity {
                    onlineUsers = append(onlineUsers, k)
                }
            }
            
            // Flush offline messages if any exist
            pendingPackets, hashPending := offlineQueue[userIdentity]
            if hashPending {
                for _, queuedPacket := range pendingPackets {
                    packetBytes, _ := json.Marshal(queuedPacket)
                    ws.WriteMessage(websocket.TextMessage, packetBytes)
                }
                delete(offlineQueue, userIdentity)
            }
            mutex.Unlock()
            
            // --- Send initial list of online users to the newcomer ---
            onlineListBytes, _ := json.Marshal(onlineUsers)
            initialStatusPacket := Packet{
                Type:     "status_update",
                FromUser: "server",
                ToUser:   userIdentity,
                Payload:  string(onlineListBytes),
            }
            initialBytes, _ := json.Marshal(initialStatusPacket)
            ws.WriteMessage(websocket.TextMessage, initialBytes)

            // --- Broadcast to everyone else that this user is now online ---
            broadcastStatus(userIdentity, true)

            displayLen := 25
            if len(userIdentity) < displayLen {
                displayLen = len(userIdentity)
            }
            fmt.Printf("Registered Connection Pipeline for Public Key: [%s...]\n", userIdentity[:displayLen])

        case "message":
            targetUser := strings.TrimSpace(p.ToUser)
            mutex.Lock()
            recipientConn, found := clients[targetUser]

            if found {
                mutex.Unlock()
                packetBytes, _ := json.Marshal(p)
                recipientConn.WriteMessage(websocket.TextMessage, packetBytes)
            } else {
                offlineQueue[targetUser] = append(offlineQueue[targetUser], p)
                mutex.Unlock()
            }
        }
    }
}

func main() {
    http.HandleFunc("/ws", handleConnections)
    fmt.Println("Server running on :8080")
    http.ListenAndServe(":8080", nil)
}