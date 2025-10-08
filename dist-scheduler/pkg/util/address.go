// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package util

import "strings"

func GRPCAddress(addr string, port string) string {
	// Returns an address that can be used with grpc.NewClient
	if strings.Contains(addr, ":") {
		addr = "[" + addr + "]"
	}
	return addr + ":" + port
}
