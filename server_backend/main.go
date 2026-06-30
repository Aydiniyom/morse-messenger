package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings" // Ensure this is imported
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
				fmt.Printf("Node disconnected: [%s...]\n", userIdentity[:15])
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
			mutex.Unlock()
			fmt.Printf("Registered Connection Pipeline for Public Key: [%s...]\n", userIdentity[:25])

		case "message":
			targetUser := strings.TrimSpace(p.ToUser) // clean routing key
			mutex.Lock()
			recipientConn, found := clients[targetUser]
			mutex.Unlock()

			if found {
				packetBytes, _ := json.Marshal(p)
				recipientConn.WriteMessage(websocket.TextMessage, packetBytes)
				fmt.Printf("Routed pure p2p packet directly to: [%s...]\n", targetUser[:15])
			} else {
				fmt.Printf("Target node [%s...] is currently offline.\n", targetUser[:15])
			}
		}
	}
}

func main() {
	http.HandleFunc("/ws", handleConnections)
	fmt.Println("🚀 Pure Asymmetric P2P Routing Node running on :8080")
	http.ListenAndServe(":8080", nil)
}