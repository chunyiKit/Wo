// wo-computer is an explicit local backup tool. It never applies phone records.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "wo-computer:", err)
		os.Exit(1)
	}
}
func output(w io.Writer, value any) error { return json.NewEncoder(w).Encode(value) }
func run(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		return errors.New("command required: serve, pair, upload, fetch, pack-public, pack-sealed, restore-public, restore-sealed")
	}
	switch args[0] {
	case "serve":
		return serve(ctx, args[1:], stdout, stderr)
	default:
		return clientCommand(ctx, args, stdout, stderr)
	}
}
