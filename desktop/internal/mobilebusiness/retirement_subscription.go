package mobilebusiness

import (
	"errors"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var retireDecimal = regexp.MustCompile(`^-?[0-9]{1,12}(\.[0-9]{1,2})?$`)

func ParseRetirementMinor(input string) (int64, error) {
	if !retireDecimal.MatchString(input) {
		return 0, ErrMoney
	}
	negative := strings.HasPrefix(input, "-")
	parts := strings.Split(strings.TrimPrefix(input, "-"), ".")
	whole, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return 0, ErrMoney
	}
	minor := whole * 100
	if len(parts) == 2 {
		fraction := parts[1]
		if len(fraction) == 1 {
			fraction += "0"
		}
		n, err := strconv.ParseInt(fraction, 10, 64)
		if err != nil {
			return 0, ErrMoney
		}
		minor += n
	}
	if minor > 99_999_999_999_999 {
		return 0, ErrMoney
	}
	if negative {
		minor = -minor
	}
	return minor, nil
}
func HalfEvenMinor(numerator, denominator int64) (int64, error) {
	if numerator < 0 || denominator < 1 || numerator > 9_007_199_254_740_991 {
		return 0, ErrMoney
	}
	q, r := numerator/denominator, numerator%denominator
	if r > denominator-r || r == denominator-r && q%2 == 1 {
		q++
	}
	return q, nil
}
func AdvanceSubscriptionDue(current, cycle string) (string, error) {
	date, err := time.Parse("2006-01-02", current)
	if err != nil {
		return "", err
	}
	year, month := date.Year(), date.Month()
	switch cycle {
	case "yearly":
		year++
	case "monthly":
		month++
		if month > 12 {
			month = 1
			year++
		}
	default:
		return "", errors.New("invalid cycle")
	}
	if year > 9999 {
		return "", errors.New("date range")
	}
	last := time.Date(year, month+1, 0, 0, 0, 0, 0, time.UTC).Day()
	day := date.Day()
	if day > last {
		day = last
	}
	return time.Date(year, month, day, 0, 0, 0, 0, time.UTC).Format("2006-01-02"), nil
}
func IncomeEligible(created, today string, payday int) (bool, error) {
	c, err := time.Parse("2006-01-02", created)
	if err != nil {
		return false, err
	}
	t, err := time.Parse("2006-01-02", today)
	if err != nil {
		return false, err
	}
	if payday < 1 || payday > 28 {
		return false, errors.New("invalid payday")
	}
	if c.After(t) || t.Day() < payday {
		return false, nil
	}
	if c.Year() == t.Year() && c.Month() == t.Month() && c.Day() > payday {
		return false, nil
	}
	return true, nil
}
func RetirementMonths(today, target string) (int, error) {
	t, err := time.Parse("2006-01-02", today)
	if err != nil {
		return 0, err
	}
	r, err := time.Parse("2006-01-02", target)
	if err != nil {
		return 0, err
	}
	months := (r.Year()-t.Year())*12 + int(r.Month()-t.Month())
	if months < 0 {
		months = 0
	}
	return months, nil
}
