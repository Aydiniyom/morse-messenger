package main

import (
	"fmt"
	"net/http"

	"github.com/gorilla/websocket"
)


var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}

func handleConnections(w http.ResponseWriter, r *http.Request) {
	
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		fmt.Println("Error upgrading connection:", err)
		return
	}
	defer ws.Close()

	fmt.Println("A user has connected securely to the node.")

	
	for {
		_, message, err := ws.ReadMessage()
		if err != nil {
			fmt.Println("User disconnected.")
			break
		}
		
		fmt.Printf("Received Raw Payload: %s\n", message)

		
		err = ws.WriteMessage(websocket.TextMessage, message)
		if err != nil {
			break
		}
	}
}

func main() {
	http.HandleFunc("/ws", handleConnections)
	
	fmt.Println("Server started on :8080")
	err := http.ListenAndServe(":8080", nil)
	if err != nil {
		fmt.Println("Server failed to start:", err)
	}
}