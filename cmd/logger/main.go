package main

import (
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/kardianos/service"
)

var logger service.Logger

type program struct {
	exit    chan struct{}
	logFile *os.File
}

func (p *program) Start(s service.Service) error {
	p.exit = make(chan struct{})
	go p.run()
	return nil
}

func (p *program) run() {
	programData := os.Getenv("PROGRAMDATA")
	if programData == "" {
		programData = `C:\ProgramData`
	}
	
	logDir := filepath.Join(programData, "1stProtect")
	os.MkdirAll(logDir, 0755)
	
	logPath := filepath.Join(logDir, "app.log")
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err == nil {
		p.logFile = f
		log.SetOutput(f)
	}

	log.Printf("1stProtect Logger started at %v", time.Now().Format(time.RFC3339))
	ticker := time.NewTicker(5 * time.Second)

	for {
		select {
		case <-ticker.C:
			logLevel := os.Getenv("LOG_LEVEL")
			if logLevel == "" {
				logLevel = "INFO"
			}
			log.Printf("[%s] Background process running timestamp=%v", logLevel, time.Now().Unix())
			
		case <-p.exit:
			log.Printf("Logger stopping at %v", time.Now().Format(time.RFC3339))
			if p.logFile != nil {
				p.logFile.Close()
			}
			ticker.Stop()
			return
		}
	}
}

func (p *program) Stop(s service.Service) error {
	close(p.exit)
	return nil
}

func main() {
	svcConfig := &service.Config{
		Name:        "1stProtectLogger",
		DisplayName: "1stProtect Logger",
		Description: "Background logger for the 1stProtect QA Assignment",
	}
	prg := &program{}
	s, err := service.New(prg, svcConfig)
	if err != nil { log.Fatal(err) }

	logger, err = s.Logger(nil)
	if len(os.Args) > 1 {
		err = service.Control(s, os.Args[1])
		if err != nil { log.Fatal(err) }
		return
	}
	s.Run()
}
