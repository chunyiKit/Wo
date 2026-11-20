package mobilebusiness

import "testing"

func TestMoneyUsesMinorIntegersWithoutRounding(t *testing.T) {
	for text, want := range map[string]int64{"0": 0, "0.1": 10, "0.01": 1, "12.34": 1234, "-12.34": -1234, "9999999999.99": 999_999_999_999} {
		got, err := ParseMinor(text)
		if err != nil || got != want {
			t.Fatal(text, got, err)
		}
		if back, err := ParseMinor(FormatMinor(got)); err != nil || back != got {
			t.Fatal("roundtrip", text, back, err)
		}
	}
	for _, text := range []string{"NaN", "Infinity", "1e3", "0.001", "0.30000000000000004", "-0.001", "10000000000", "1.", ".1", " 1.00", "1.00 ", "+1"} {
		if _, err := ParseMinor(text); err == nil {
			t.Fatal("rounded/accepted", text)
		}
	}
	a, _ := ParseMinor("0.1")
	b, _ := ParseMinor("0.2")
	if FormatMinor(a+b) != "0.30" {
		t.Fatal(a + b)
	}
}
func TestCalendarMonthsHandleLeapDayAndYearBoundary(t *testing.T) {
	entries := []ExpenseOracle{{100, "2024-02-01", false}, {20, "2024-02-29", true}, {900, "2024-03-01", false}, {5, "2025-12-31", false}, {7, "2026-01-01", false}}
	budget := int64(200)
	got, err := CalendarSummary(entries, 2024, 2, &budget)
	if err != nil || got.Total != 120 || got.Budgeted != 100 || got.Excluded != 20 || got.Remaining == nil || *got.Remaining != 100 {
		t.Fatal(got, err)
	}
	got, err = CalendarSummary(entries, 2025, 12, nil)
	if err != nil || got.Total != 5 || got.Remaining != nil {
		t.Fatal(got, err)
	}
	got, err = CalendarSummary(entries, 2026, 1, nil)
	if err != nil || got.Total != 7 {
		t.Fatal(got, err)
	}
	for _, bad := range []string{"2023-02-29", "2024-02-30", "2024-13-01", "2024-1-01"} {
		if _, err := CalendarSummary([]ExpenseOracle{{1, bad, false}}, 2024, 2, nil); err == nil {
			t.Fatal("invalid date", bad)
		}
	}
	if _, err := CalendarSummary(entries, 2024, 13, nil); err == nil {
		t.Fatal("invalid month")
	}
}
func TestRefundAndOverBudgetRemainSigned(t *testing.T) {
	budget := int64(100)
	got, err := CalendarSummary([]ExpenseOracle{{200, "2026-11-01", false}, {-25, "2026-11-02", false}, {50, "2026-11-03", true}}, 2026, 11, &budget)
	if err != nil || got.Total != 225 || got.Budgeted != 175 || got.Excluded != 50 || *got.Remaining != -75 {
		t.Fatal(got, err)
	}
}
