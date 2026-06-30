package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sync"

	"github.com/gorilla/websocket"
)

// define what our data packets look like
type Packet struct {
	Type     string `json:"type"`     // "register" or "message"
	FromUser string `json:"fromUser"` // sender's public key fingerprint
	ToUser   string `json:"toUser"`   // recipient's public key fingerprint
	Payload  string `json:"payload"`  // the encrypted scrambled text
}

// a secure, thread-safe phone book to store active user connections
var clients = make(map[string]*websocket.Conn)
var mutex = &sync.Mutex{}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

func handleConnections(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer ws.Close()

	var userFingerprint string

	for {
		_, message, err := ws.ReadMessage()
		if err != nil {
			// clean up when a user disconnects
			if userFingerprint != "" {
				mutex.Lock()
				delete(clients, userFingerprint)
				mutex.Unlock()
				fmt.Printf("User [%s] disconnected.\n", userFingerprint[:10])
			}
			break
		}

		// read the JSON packet sent by the app
		var packet Packet
		err = json.Unmarshal(message, &packet)
		if err != nil {
			fmt.Println("Error reading packet format:", err)
			continue
		}

		switch packet.Type {
		case "register":
			// register the user's connection in our phone book
			userFingerprint = packet.FromUser
			mutex.Lock()
			clients[userFingerprint] = ws
			mutex.Unlock()
			fmt.Printf("Node Registered Identity: [%s...]\n", userFingerprint[:15])

		case "message":
			fmt.Printf("Routing packet from [%s...] to [%s...]\n", packet.FromUser[:8], packet.ToUser[:8])
			
			// look up the recipient in our phone book
			mutex.Lock()
			recipientConn, found := clients[packet.ToUser]
			mutex.Unlock()

			if found {
				// forward the exact raw encrypted packet to the recipient
				packetBytes, _ := json.Marshal(packet)
				recipientConn.WriteMessage(websocket.TextMessage, packetBytes)
			} else {
				fmt.Println("Recipient is offline. (In future, we will cache this!)")
			}
		}
	}
}

func main() {
	http.HandleFunc("/ws", handleConnections)
	fmt.Println("Routing node running on :8080")
	http.ListenAndServe(":8080", nil)
}