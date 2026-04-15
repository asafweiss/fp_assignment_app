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

var logger service.Logger

type program struct {
	exit   chan struct{}
	server *http.Server
}

func getLoggerStatus() string {
	m, err := mgr.Connect()
	if err != nil {
		return "Stopped" // Assume error connecting implies stopped or inaccessible
	}
	defer m.Disconnect()

	s, err := m.OpenService("1stProtectLogger")
	if err != nil {
		return "Stopped" // Not found implies stopped
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

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": getLoggerStatus()})
}

func (p *program) Start(s service.Service) error {
	p.exit = make(chan struct{})
	go p.run()
	return nil
}

func (p *program) run() {
	p.server = &http.Server{}
	http.HandleFunc("/health", healthHandler)

	listener, err := net.Listen("tcp", "0.0.0.0:0")
	if err == nil {
		port := listener.Addr().(*net.TCPAddr).Port
		
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

	<-p.exit
	p.server.Close()
}

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
	if err != nil { log.Fatal(err) }

	logger, err = srv.Logger(nil)
	if len(os.Args) > 1 {
		err = service.Control(srv, os.Args[1])
		if err != nil { log.Fatal(err) }
		return
	}
	srv.Run()
}
