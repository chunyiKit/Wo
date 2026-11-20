package mobilebusiness

import "testing"

func TestRetirementMinorKeepsFourteenDigitPrecision(t *testing.T) {
	for text, want := range map[string]int64{"999999999999.99": 99_999_999_999_999, "-0.01": -1, "10000000000.01": 1_000_000_000_001} {
		got, err := ParseRetirementMinor(text)
		if err != nil || got != want {
			t.Fatal(text, got, err)
		}
	}
	for _, text := range []string{"1000000000000.00", "0.001", "NaN", "1e4"} {
		if _, err := ParseRetirementMinor(text); err == nil {
			t.Fatal("invalid money", text)
		}
	}
}
func TestRequiredMonthlyUsesDecimalHalfEvenCents(t *testing.T) {
	for _, item := range []struct{ n, d, want int64 }{{5, 2, 2}, {7, 2, 4}, {4, 3, 1}, {5, 3, 2}, {0, 12, 0}, {12345, 12, 1029}} {
		got, err := HalfEvenMinor(item.n, item.d)
		if err != nil || got != item.want {
			t.Fatal(item, got, err)
		}
	}
}
func TestSubscriptionPreservesLegacyClampCalendar(t *testing.T) {
	for _, item := range []struct{ date, cycle, want string }{{"2023-01-31", "monthly", "2023-02-28"}, {"2023-02-28", "monthly", "2023-03-28"}, {"2024-01-31", "monthly", "2024-02-29"}, {"2024-02-29", "yearly", "2025-02-28"}, {"2025-12-31", "monthly", "2026-01-31"}} {
		got, err := AdvanceSubscriptionDue(item.date, item.cycle)
		if err != nil || got != item.want {
			t.Fatal(item, got, err)
		}
	}
	for _, bad := range []string{"2023-02-29", "2024-13-01"} {
		if _, err := AdvanceSubscriptionDue(bad, "monthly"); err == nil {
			t.Fatal(bad)
		}
	}
}
func TestIncomeCreationMonthAndRetirementCalendarBoundary(t *testing.T) {
	for _, item := range []struct {
		created, today string
		day            int
		want           bool
	}{{"2026-11-20", "2026-11-30", 1, false}, {"2026-11-01", "2026-11-20", 1, true}, {"2026-10-20", "2026-11-01", 1, true}, {"2026-12-01", "2026-11-30", 1, false}, {"2026-10-01", "2026-11-02", 3, false}} {
		got, err := IncomeEligible(item.created, item.today, item.day)
		if err != nil || got != item.want {
			t.Fatal(item, got, err)
		}
	}
	months, err := RetirementMonths("2026-12-31", "2027-01-01")
	if err != nil || months != 1 {
		t.Fatal(months, err)
	}
	months, err = RetirementMonths("2026-11-20", "2026-11-30")
	if err != nil || months != 0 {
		t.Fatal(months, err)
	}
}
