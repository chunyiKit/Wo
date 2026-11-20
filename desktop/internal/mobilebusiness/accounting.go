package mobilebusiness

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var ErrMoney = errors.New("money must be finite decimal with at most two fraction digits")
var decimalMoney = regexp.MustCompile(`^-?[0-9]{1,10}(\.[0-9]{1,2})?$`)

// ParseMinor accepts decimal text without floating point multiplication or
// rounding. Its 12-digit minor ceiling matches the legacy NUMERIC(12,2).
func ParseMinor(input string) (int64, error) {
	if !decimalMoney.MatchString(input) {
		return 0, ErrMoney
	}
	negative := strings.HasPrefix(input, "-")
	unsigned := strings.TrimPrefix(input, "-")
	parts := strings.Split(unsigned, ".")
	whole, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return 0, ErrMoney
	}
	fraction := int64(0)
	if len(parts) == 2 {
		f := parts[1]
		if len(f) == 1 {
			f += "0"
		}
		fraction, err = strconv.ParseInt(f, 10, 64)
		if err != nil {
			return 0, ErrMoney
		}
	}
	minor := whole*100 + fraction
	if minor > 999_999_999_999 {
		return 0, ErrMoney
	}
	if negative {
		minor = -minor
	}
	return minor, nil
}
func FormatMinor(minor int64) string {
	sign := ""
	if minor < 0 {
		sign = "-"
		minor = -minor
	}
	return fmt.Sprintf("%s%d.%02d", sign, minor/100, minor%100)
}

type ExpenseOracle struct {
	Minor        int64
	CalendarDate string
	Excluded     bool
}
type AccountingTotals struct {
	Total, Budgeted, Excluded int64
	Remaining                 *int64
}

// CalendarSummary uses a persisted wall-calendar date, not a rolling 30-day
// window, UTC timestamp prefix or the caller's later travel timezone.
func CalendarSummary(expenses []ExpenseOracle, year, month int, budget *int64) (AccountingTotals, error) {
	var out AccountingTotals
	if year < 1 || year > 9999 || month < 1 || month > 12 {
		return out, errors.New("invalid calendar month")
	}
	prefix := fmt.Sprintf("%04d-%02d", year, month)
	for _, e := range expenses {
		parsed, err := time.Parse("2006-01-02", e.CalendarDate)
		if err != nil || parsed.Format("2006-01-02") != e.CalendarDate {
			return out, errors.New("invalid persisted calendar date")
		}
		if !strings.HasPrefix(e.CalendarDate, prefix+"-") {
			continue
		}
		if e.Minor < -999_999_999_999 || e.Minor > 999_999_999_999 {
			return out, ErrMoney
		}
		out.Total += e.Minor
		if e.Excluded {
			out.Excluded += e.Minor
		} else {
			out.Budgeted += e.Minor
		}
		if out.Total < -9_007_199_254_740_991 || out.Total > 9_007_199_254_740_991 || out.Budgeted < -9_007_199_254_740_991 || out.Budgeted > 9_007_199_254_740_991 || out.Excluded < -9_007_199_254_740_991 || out.Excluded > 9_007_199_254_740_991 {
			return out, ErrMoney
		}
	}
	if budget != nil {
		if *budget < 0 || *budget > 999_999_999_999 {
			return out, ErrMoney
		}
		remaining := *budget - out.Budgeted
		out.Remaining = &remaining
	}
	return out, nil
}
