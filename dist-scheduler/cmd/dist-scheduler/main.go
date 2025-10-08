// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package main

import (
	"log"
)

func main() {
	cmd := NewSchedulerCommand()

	err := cmd.Execute()
	if err != nil {
		log.Fatalf("Failed to execute scheduler: %v", err)
	}
}
