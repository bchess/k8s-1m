// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package util

import "sync"

type CountDownLatch interface {
	Done()
	Wait()
}

func NewCountDownLatch(n int, ratio float64) CountDownLatch {
	if ratio > 0.999999 {
		r := &CountDownLatchAsWaitGroup{wg: sync.WaitGroup{}}
		r.wg.Add(n)
		return r
	}
	c := &CountDownLatchAsMutex{count: int(float64(n) * ratio)}
	c.cond = sync.NewCond(&c.mu)
	return c
}

type CountDownLatchAsMutex struct {
	mu    sync.Mutex
	count int
	cond  *sync.Cond
}

func (c *CountDownLatchAsMutex) Done() {
	c.mu.Lock()
	c.count--
	if c.count <= 0 {
		c.cond.Broadcast()
	}
	c.mu.Unlock()
}

func (c *CountDownLatchAsMutex) Wait() {
	c.mu.Lock()
	for c.count > 0 {
		c.cond.Wait()
	}
	c.mu.Unlock()
}

type CountDownLatchAsWaitGroup struct {
	wg sync.WaitGroup
}

func (c *CountDownLatchAsWaitGroup) Done() {
	c.wg.Done()
}

func (c *CountDownLatchAsWaitGroup) Wait() {
	c.wg.Wait()
}
