// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package util

import (
	"sync"
)

type Stack[T any] struct {
	items []T
	mu    sync.Mutex
	cond  *sync.Cond
}

func NewStack[T any](items []T) *Stack[T] {
	stack := &Stack[T]{
		items: make([]T, len(items)),
	}
	stack.cond = sync.NewCond(&stack.mu)
	copy(stack.items, items)
	return stack
}

func (s *Stack[T]) Push(item T) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.items = append(s.items, item)
	s.cond.Signal()
}

func (s *Stack[T]) Pop() T {
	s.mu.Lock()
	defer s.mu.Unlock()

	for len(s.items) == 0 {
		s.cond.Wait()
	}

	lastIdx := len(s.items) - 1
	item := s.items[lastIdx]
	s.items = s.items[:lastIdx]
	return item
}

// Len returns the number of items in the stack.
func (s *Stack[T]) Len() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.items)
}
