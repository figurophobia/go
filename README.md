# Checkpoint 1 – Project Proposal

## 1. Repository

Repository platform: GitHub / GitLab

Repository link: (add your link here)

Access: Public or teacher added as collaborator

---

## 2. Project Description

**Project Name:** Go Multiplayer (Godot)

**Description:**
This project consists of a multiplayer implementation of the classic board game Go. The game will follow a client-server architecture, allowing two players to connect and play against each other in real time (turn-based system).

The system will validate moves, enforce the rules of Go, and synchronize the game state between both players.

**Game Type:** Turn-based multiplayer game

---

## 3. Selected Technology

- Engine: Godot
- Language: GDScript (or C# if chosen)
- Networking: TCP sockets

**Justification:**
- Godot provides built-in networking support (RPCs, ENet)
- Easy separation between game logic and networking
- Simple UI implementation
- Cross-platform support

---

## 4. Team Responsibilities

### Member 1 – Networking
- Client-server communication implementation
- Connection handling
- Disconnection handling
- Game state synchronization

### Member 2 – Game Logic
- Implementation of Go rules:
  - Stone placement
  - Captures
  - Suicide rule
  - Ko rule (optional)
- Move validation

### Member 3 – UI & Input
- Board interface
- Player input handling
- Error messages for invalid moves
- Turn management display


## 5. Technical Design

### Architecture

Client (Player 1)  ----\
                        ---> Server (authoritative game state)
Client (Player 2)  ----/

### Basic Flow

1. Client connects to server
2. Server assigns turns
3. Player sends move
4. Server:
   - validates the move
   - updates the board
   - sends updated state to both clients
5. Repeat until game ends
