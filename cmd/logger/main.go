// Package main implements the 1stProtectLogger Windows service.
//
// The Logger is one of two services that make up the 1stProtect application.
// Its sole responsibility is to write timestamped, log-level-tagged entries to
// a shared log file at a fixed interval, simulating a background worker process.
//
// Behaviour
//   - Registers itself as Windows service "1stProtectLogger" via kardianos/service.
//   - On Start: opens (or creates) %PROGRAMDATA%\1stProtect\app.log in append mode,
//     then launches the main loop in a goroutine.
//   - Main loop: every 5 seconds, writes one line:
//       [<LOG_LEVEL>] Background process running timestamp=<unix>
//     LOG_LEVEL is read from the process environment on each tick so that it can
//     be changed without restarting the service (useful for testing).  If LOG_LEVEL
//     is not set, it defaults to "INFO".  Unrecognised values are used verbatim —
//     the Logger never crashes on bad input.
//   - On Stop: signals the loop to exit cleanly, closes the log file.

package main

import (
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/kardianos/service"
)

// logger holds the service-provided logger (used for SCM event log, not app.log).
var logger service.Logger

// program implements the service.Interface required by kardianos/service.
type program struct {
	exit    chan struct{} // closed by Stop() to signal the run loop to exit
	logFile *os.File     // handle kept open for the duration of the service lifetime
}

// Start is called by the SCM when the service is started.
// It initialises the exit channel and launches the main loop in a goroutine,
// returning immediately so the SCM does not time out.
func (p *program) Start(s service.Service) error {
	p.exit = make(chan struct{})
	go p.run()
	return nil
}

// run is the service's main loop.  It opens app.log and then ticks every 5 seconds.
func (p *program) run() {
	// Resolve the data directory from the environment; fall back to the default path
	// so the service works even if PROGRAMDATA is not set (unusual but possible).
	programData := os.Getenv("PROGRAMDATA")
	if programData == "" {
		programData = `C:\ProgramData`
	}

	logDir := filepath.Join(programData, "1stProtect")
	os.MkdirAll(logDir, 0755) // ensure the directory exists before opening the file

	logPath := filepath.Join(logDir, "app.log")
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err == nil {
		p.logFile = f
		log.SetOutput(f) // redirect the standard logger to our file
	}

	log.Printf("1stProtect Logger started at %v", time.Now().Format(time.RFC3339))
	ticker := time.NewTicker(5 * time.Second)

	for {
		select {
		case <-ticker.C:
			// Read LOG_LEVEL on every tick — allows dynamic level changes for testing.
			// Unknown values are used as-is; the Logger never panics on bad input.
			logLevel := os.Getenv("LOG_LEVEL")
			if logLevel == "" {
				logLevel = "INFO"
			}
			log.Printf("[%s] Background process running timestamp=%v", logLevel, time.Now().Unix())

		case <-p.exit:
			// Graceful shutdown: log the stop event, close the file, stop the ticker.
			log.Printf("Logger stopping at %v", time.Now().Format(time.RFC3339))
			if p.logFile != nil {
				p.logFile.Close()
			}
			ticker.Stop()
			return
		}
	}
}

// Stop is called by the SCM when the service is stopped.
// Closing the exit channel unblocks the select in run(), triggering clean shutdown.
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
	if err != nil {
		log.Fatal(err)
	}

	logger, err = s.Logger(nil)

	// When run with a command-line argument (install/uninstall/start/stop),
	// delegate to the service control manager and exit.
	if len(os.Args) > 1 {
		err = service.Control(s, os.Args[1])
		if err != nil {
			log.Fatal(err)
		}
		return
	}

	// No arguments → run as a service (normal SCM-managed execution path).
	s.Run()
}
