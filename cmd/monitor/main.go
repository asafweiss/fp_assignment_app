// Package main implements the 1stProtectMonitor Windows service.
//
// The Monitor is one of two services that make up the 1stProtect application.
// Its responsibility is to expose a /health HTTP endpoint that reports the
// real-time status of the companion Logger service, allowing external tools
// (and the test suite) to query application health without direct WMI or SCM
// access.
//
// Behaviour
//   - Registers itself as Windows service "1stProtectMonitor" via kardianos/service.
//   - On Start: binds an HTTP listener on a random free port (0.0.0.0:0), writes
//     the assigned port number to %PROGRAMDATA%\1stProtect\port.txt so that the
//     test runner can discover it, then serves HTTP requests in a goroutine.
//   - GET /health: queries the Windows SCM for the "1stProtectLogger" service state
//     and responds with {"status": "Running"} or {"status": "Stopped"}.
//   - On Stop: signals the HTTP server to shut down.

package main

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"

	"github.com/kardianos/service"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

// logger holds the service-provided logger for SCM event log entries.
var logger service.Logger

// program implements the service.Interface required by kardianos/service.
type program struct {
	exit   chan struct{} // closed by Stop() to signal the HTTP server to shut down
	server *http.Server
}

// getLoggerStatus queries the Windows Service Control Manager for the current
// state of 1stProtectLogger and returns a human-readable string.
//
// Returns "Running" only when the SCM reports the service as actively running.
// Returns "Stopped" for any other state or error (not found, access denied, etc.)
// so that the health endpoint always returns a determinate, safe value.
func getLoggerStatus() string {
	m, err := mgr.Connect()
	if err != nil {
		return "Stopped" // Cannot reach SCM → treat as stopped
	}
	defer m.Disconnect()

	s, err := m.OpenService("1stProtectLogger")
	if err != nil {
		return "Stopped" // Service not registered → treat as stopped
	}
	defer s.Close()

	q, err := s.Query()
	if err != nil {
		return "Error"
	}

	if q.State == svc.Running {
		return "Running"
	}
	return "Stopped"
}

// healthHandler serves GET /health.
// Response: 200 OK with JSON body {"status": "Running"|"Stopped"}
func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": getLoggerStatus()})
}

// Start is called by the SCM when the service is started.
func (p *program) Start(s service.Service) error {
	p.exit = make(chan struct{})
	go p.run()
	return nil
}

// run binds the HTTP listener, writes port.txt, and starts serving.
func (p *program) run() {
	p.server = &http.Server{}
	http.HandleFunc("/health", healthHandler)

	// Bind to port 0 — the OS assigns the next available free port.
	// This avoids hardcoded port conflicts and makes the service usable
	// in environments where specific ports may be occupied.
	listener, err := net.Listen("tcp", "0.0.0.0:0")
	if err == nil {
		port := listener.Addr().(*net.TCPAddr).Port

		// Persist the port so external tools can discover it without scanning.
		programData := os.Getenv("PROGRAMDATA")
		if programData == "" {
			programData = `C:\ProgramData`
		}
		logDir := filepath.Join(programData, "1stProtect")
		os.MkdirAll(logDir, 0755)
		portFilePath := filepath.Join(logDir, "port.txt")
		os.WriteFile(portFilePath, []byte(strconv.Itoa(port)), 0644)

		go func() {
			p.server.Serve(listener)
		}()
	}

	// Block until Stop() closes the exit channel.
	<-p.exit
	p.server.Close()
}

// Stop is called by the SCM when the service is stopped.
func (p *program) Stop(s service.Service) error {
	close(p.exit)
	return nil
}

func main() {
	svcConfig := &service.Config{
		Name:        "1stProtectMonitor",
		DisplayName: "1stProtect Monitor",
		Description: "Background monitor for the 1stProtect QA Assignment",
	}
	prg := &program{}
	srv, err := service.New(prg, svcConfig)
	if err != nil {
		log.Fatal(err)
	}

	logger, err = srv.Logger(nil)

	// Delegate service control commands (install/uninstall/start/stop) to the SCM.
	if len(os.Args) > 1 {
		err = service.Control(srv, os.Args[1])
		if err != nil {
			log.Fatal(err)
		}
		return
	}

	// No arguments → run as a service.
	srv.Run()
}
