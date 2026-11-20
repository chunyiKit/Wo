package mobilebusiness

import (
	"math/rand"
	"reflect"
	"testing"
)

func TestStockConcurrentDeltasAndReceiptCyclesConverge(t *testing.T) {
	events := []StockEvent{
		{ID: "initial", Actor: "A", Type: "delta", ItemID: "rice", Order: 1, Delta: 10},
		{ID: "useA", Actor: "A", Type: "delta", ItemID: "rice", Order: 2, Delta: -2},
		{ID: "useB", Actor: "B", Type: "delta", ItemID: "rice", Order: 2, Delta: -3},
		{ID: "receipt0", Actor: "A", Type: "receipt", ItemID: "rice", BuyID: "buy", Cycle: "initial", Order: 3, Delta: 4},
		{ID: "receipt0", Actor: "B", Type: "receipt", ItemID: "rice", BuyID: "buy", Cycle: "initial", Order: 3, Delta: 4},
		{ID: "reopen", Actor: "A", Type: "reopen", BuyID: "buy", Cycle: "initial", NextCycle: "cycle1", Order: 4},
		{ID: "receipt1", Actor: "A", Type: "receipt", ItemID: "rice", BuyID: "buy", Cycle: "cycle1", Order: 5, Delta: 2},
	}
	want, err := ProjectStock(events)
	if err != nil {
		t.Fatal(err)
	}
	if want.Quantity["rice"] != 11 || want.Conflicts["rice"] || !want.Purchases["buy"].Bought {
		t.Fatal(want)
	}
	rng := rand.New(rand.NewSource(431))
	for range 100 {
		rng.Shuffle(len(events), func(i, j int) { events[i], events[j] = events[j], events[i] })
		got, err := ProjectStock(events)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("non-convergent %v %v", got, err)
		}
	}
}
func TestNegativeMergedStockIsVisibleAndNeverClamped(t *testing.T) {
	events := []StockEvent{{ID: "seed", Actor: "A", Type: "delta", ItemID: "rice", Order: 1, Delta: 3}, {ID: "useA", Actor: "A", Type: "delta", ItemID: "rice", Order: 2, Delta: -2}, {ID: "useB", Actor: "B", Type: "delta", ItemID: "rice", Order: 2, Delta: -2}}
	got, err := ProjectStock(events)
	if err != nil || got.Quantity["rice"] != -1 || !got.Conflicts["rice"] {
		t.Fatalf("negative conflict hidden %v %v", got, err)
	}
	events = append(events, StockEvent{ID: "physical-count", Actor: "A", Type: "delta", ItemID: "rice", Order: 3, Delta: 6})
	got, err = ProjectStock(events)
	if err != nil || got.Quantity["rice"] != 5 || got.Conflicts["rice"] {
		t.Fatal(got, err)
	}
}
func TestReceiptIdCollisionFlagsBothTargets(t *testing.T) {
	got, err := ProjectStock([]StockEvent{{ID: "same", Actor: "A", Type: "receipt", ItemID: "one", BuyID: "buy", Cycle: "initial", Order: 1, Delta: 2}, {ID: "same", Actor: "B", Type: "receipt", ItemID: "two", BuyID: "buy", Cycle: "initial", Order: 1, Delta: 3}})
	if err != nil || !got.Conflicts["one"] || !got.Conflicts["two"] || got.Quantity["one"] != 2 {
		t.Fatal(got, err)
	}
}
func TestReopenDoesNotUndoReceipt(t *testing.T) {
	got, err := ProjectStock([]StockEvent{{ID: "receipt", Actor: "A", Type: "receipt", ItemID: "one", BuyID: "buy", Cycle: "initial", Order: 1, Delta: 2}, {ID: "reopen", Actor: "A", Type: "reopen", BuyID: "buy", Cycle: "initial", NextCycle: "next", Order: 2}})
	if err != nil || got.Quantity["one"] != 2 || got.Purchases["buy"].Bought {
		t.Fatal(got, err)
	}
}
func TestInvalidStockEventsRejected(t *testing.T) {
	for _, e := range []StockEvent{{}, {ID: "bad", Actor: "A", Type: "receipt", BuyID: "b", Cycle: "initial", Order: 1, Delta: -1}, {ID: "bad", Actor: "A", Type: "receipt", BuyID: "b", Cycle: "initial", Order: 1, Delta: 1}, {ID: "bad", Actor: "A", Type: "delta", ItemID: "s", Order: 1, Delta: 9_007_199_254_740_992}} {
		if _, err := ProjectStock([]StockEvent{e}); err == nil {
			t.Fatal("accepted", e)
		}
	}
}

func TestLargeConflictCanBeCorrectedByPhysicalStocktake(t *testing.T) {
	events := []StockEvent{{ID: "seed", Actor: "A", Type: "delta", ItemID: "rice", Order: 1, Delta: 1_000_000_000}}
	for i, actor := range []string{"A", "B", "C", "D"} {
		events = append(events, StockEvent{ID: "consume" + actor, Actor: actor, Type: "delta", ItemID: "rice", Order: int64(i + 2), Delta: -1_000_000_000})
	}
	events = append(events, StockEvent{ID: "count", Actor: "A", Type: "delta", ItemID: "rice", Order: 7, Delta: 3_000_000_005})
	got, err := ProjectStock(events)
	if err != nil || got.Quantity["rice"] != 5 || got.Conflicts["rice"] {
		t.Fatal(got, err)
	}
}
