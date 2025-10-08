// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Benjamin Chess
package scoreevaluator

import (
	"context"
	"math/rand"
	"sync"
	"time"

	"bchess.org/dist-scheduler/pkg/schedulerset"
	"k8s.io/klog/v2"
)

type Score struct {
	NodeName string
	Score    int
}

type oneEvaluator struct {
	cond         sync.Cond
	limit        uint32
	scores       []Score
	ticker       *time.Ticker
	highestScore Score
	start        time.Time
}

type ScoreEvaluator struct {
	lock         sync.Mutex
	schedulerSet *schedulerset.SchedulerSet
	evaluators   map[string]*oneEvaluator
	delay        time.Duration
}

func New(delay time.Duration, schedulerSet *schedulerset.SchedulerSet) *ScoreEvaluator {
	return &ScoreEvaluator{
		lock:         sync.Mutex{},
		schedulerSet: schedulerSet,
		evaluators:   make(map[string]*oneEvaluator),
		delay:        delay,
	}
}

func (e *ScoreEvaluator) RecordAndWait(key string, score Score) Score {
	// returns the highest score for the key among all recorded
	e.lock.Lock()
	o, ok := e.evaluators[key]
	if !ok {
		o = startOneEvaluator(key, e)
		e.evaluators[key] = o
	}
	e.lock.Unlock()

	o.cond.L.Lock()
	defer o.cond.L.Unlock()
	o.scores = append(o.scores, score)
	if len(o.scores) >= int(o.limit) {
		// We have scores from all schedulers so fire early
		o.fire(e, key, true)
		return o.highestScore
	}
	o.cond.Wait()
	return o.highestScore
}

func startOneEvaluator(key string, e *ScoreEvaluator) *oneEvaluator {
	o := &oneEvaluator{
		cond: sync.Cond{
			L: &sync.Mutex{},
		},
		limit:  e.schedulerSet.GetMemberCountNoRelays(),
		scores: []Score{},
		ticker: time.NewTicker(e.delay),
		highestScore: Score{
			NodeName: "",
			Score:    -1,
		},
		start: time.Now(),
	}
	go func(o *oneEvaluator) {
		<-o.ticker.C
		o.fire(e, key, false)
	}(o)
	return o
}

func (o *oneEvaluator) fire(e *ScoreEvaluator, key string, alreadyHasLock bool) {
	logger := klog.FromContext(context.Background()).WithName("ScoreEvaluator")
	if !alreadyHasLock {
		o.cond.L.Lock()
		defer o.cond.L.Unlock()
	}
	if o.highestScore.Score != -1 {
		// We already fired
		return
	}

	// Pick highest score
	// highestScores keeps all the scores that have the highest score, and then we pick randomly among them. Only pick from 100
	maxScore := -1
	candidates := make([]Score, 0, 100)

	for _, sc := range o.scores {
		switch {
		case sc.Score > maxScore:
			// found a new best
			maxScore = sc.Score
			candidates = candidates[:0] // reset the list
			candidates = append(candidates, sc)
		case sc.Score == maxScore:
			// tie for best, add but cap at 100
			if len(candidates) < 100 {
				candidates = append(candidates, sc)
			}
		}
	}

	// There should always be at least one
	o.highestScore = candidates[rand.Intn(len(candidates))]
	logger.Info("Fired", "key", key, "winner", o.highestScore.NodeName, "winning_score", o.highestScore.Score, "score_count", len(o.scores), "duration_ms", time.Since(o.start).Milliseconds())
	e.lock.Lock()
	delete(e.evaluators, key)
	e.lock.Unlock()
	o.cond.Broadcast()
}
