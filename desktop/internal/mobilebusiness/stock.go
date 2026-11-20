// Package mobilebusiness contains independent specification oracles; it is not
// the phone's Dart implementation and does not claim to execute SQLite routes.
package mobilebusiness

import (
	"errors"
	"sort"
)

var ErrStockEvent = errors.New("invalid stock event")

type StockEvent struct {
	ID, Actor, Type, ItemID, BuyID, Cycle, NextCycle string
	Order                                            int64
	Delta                                            int64
}
type StockProjection struct {
	Quantity  map[string]int64
	Conflicts map[string]bool
	Purchases map[string]Purchase
}
type Purchase struct {
	Cycle  string
	Bought bool
	Amount int64
}

// ProjectStock keeps independent deltas, suppresses duplicate receipts by their
// immutable ID, and flags conflicting ID payloads or negative final balances.
// A stock metadata tombstone hides the item without deleting audit events.
func ProjectStock(input []StockEvent) (StockProjection, error) {
	out := StockProjection{Quantity: map[string]int64{}, Conflicts: map[string]bool{}, Purchases: map[string]Purchase{}}
	events := append([]StockEvent{}, input...)
	for _, e := range events {
		if e.ID == "" || e.Actor == "" || e.Order < 1 {
			return out, ErrStockEvent
		}
		switch e.Type {
		case "delta":
			if e.ItemID == "" || e.Delta < -9_007_199_254_740_991 || e.Delta > 9_007_199_254_740_991 {
				return out, ErrStockEvent
			}
		case "receipt":
			if e.BuyID == "" || e.Cycle == "" || e.Delta < 0 || e.Delta > 1_000_000_000 || (e.Delta > 0 && e.ItemID == "") {
				return out, ErrStockEvent
			}
		case "reopen":
			if e.BuyID == "" || e.Cycle == "" || e.NextCycle == "" {
				return out, ErrStockEvent
			}
		default:
			return out, ErrStockEvent
		}
	}
	sort.Slice(events, func(i, j int) bool {
		a, b := events[i], events[j]
		if a.Order != b.Order {
			return a.Order < b.Order
		}
		if a.Actor != b.Actor {
			return a.Actor < b.Actor
		}
		return a.ID < b.ID
	})
	seen := map[string]StockEvent{}
	for _, e := range events {
		if old, ok := seen[e.ID]; ok {
			if old.Type != e.Type || old.ItemID != e.ItemID || old.BuyID != e.BuyID || old.Cycle != e.Cycle || old.NextCycle != e.NextCycle || old.Delta != e.Delta {
				out.Conflicts[e.ItemID] = true
				out.Conflicts[old.ItemID] = true
			}
			continue
		}
		seen[e.ID] = e
		if (e.Type == "delta" || e.Type == "receipt") && e.ItemID != "" {
			out.Quantity[e.ItemID] += e.Delta
			if out.Quantity[e.ItemID] < -9_007_199_254_740_991 || out.Quantity[e.ItemID] > 9_007_199_254_740_991 {
				return out, ErrStockEvent
			}
		}
		if e.BuyID != "" {
			p, ok := out.Purchases[e.BuyID]
			if !ok {
				p.Cycle = "initial"
			}
			if p.Cycle == e.Cycle {
				if e.Type == "receipt" {
					p.Bought = true
					p.Amount = e.Delta
				}
				if e.Type == "reopen" && p.Bought {
					p.Cycle = e.NextCycle
					p.Bought = false
					p.Amount = 0
				}
			}
			out.Purchases[e.BuyID] = p
		}
	}
	for id, qty := range out.Quantity {
		if qty < 0 || qty > 1_000_000_000 {
			out.Conflicts[id] = true
		}
	}
	return out, nil
}
