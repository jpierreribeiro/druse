package workload

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strconv"
)

type SmallDocument struct {
	ID     int    `json:"id"`
	Name   string `json:"name"`
	Email  string `json:"email"`
	Active bool   `json:"active"`
}

type MediumItem struct {
	ID     int     `json:"id"`
	Name   string  `json:"name"`
	Score  float64 `json:"score"`
	Active bool    `json:"active"`
}

type MediumDocument struct {
	RequestID string       `json:"request_id"`
	Items     []MediumItem `json:"items"`
	Tags      []string     `json:"tags"`
}

// MediumItemInt is the same item with an integer score.
//
// Odin's pinned core:encoding/json renders float64 in fixed point with sixteen
// decimals, so the float document is 960 bytes larger on Druse than here for the
// same 64 items and the two cannot be compared byte for byte. This variant is
// byte-identical across every server in the matrix, and the difference between
// the two endpoints within one server isolates that server's float rendering
// cost.
type MediumItemInt struct {
	ID     int    `json:"id"`
	Name   string `json:"name"`
	Score  int    `json:"score"`
	Active bool   `json:"active"`
}

type MediumDocumentInt struct {
	RequestID string          `json:"request_id"`
	Items     []MediumItemInt `json:"items"`
	Tags      []string        `json:"tags"`
}

type RoutedResponse struct {
	ID        int  `json:"id"`
	AccountID int  `json:"account_id"`
	Verbose   bool `json:"verbose"`
}

var Small = SmallDocument{
	ID:     42,
	Name:   "Ada",
	Email:  "ada@example.com",
	Active: true,
}

var Medium = makeMedium()

var MediumInt = makeMediumInt()

func makeMediumInt() MediumDocumentInt {
	items := make([]MediumItemInt, 64)
	for i := range items {
		items[i] = MediumItemInt{
			ID:     i + 1,
			Name:   "item-abcdefghijklmnop",
			Score:  i + 1,
			Active: true,
		}
	}
	return MediumDocumentInt{
		RequestID: "req-0123456789abcdef",
		Items:     items,
		Tags:      []string{"alpha", "beta", "gamma", "delta", "epsilon", "zeta"},
	}
}

func makeMedium() MediumDocument {
	items := make([]MediumItem, 64)
	for i := range items {
		items[i] = MediumItem{
			ID:     i + 1,
			Name:   "item-abcdefghijklmnop",
			Score:  float64(i) + 1.5,
			Active: true,
		}
	}
	return MediumDocument{
		RequestID: "req-0123456789abcdef",
		Items:     items,
		Tags:      []string{"alpha", "beta", "gamma", "delta", "epsilon", "zeta"},
	}
}

func DecodeStrict(raw []byte, dst any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("trailing JSON value")
		}
		return err
	}
	return nil
}

func ParseRouted(idText, verboseText string, accountID int) (RoutedResponse, error) {
	id, err := strconv.Atoi(idText)
	if err != nil {
		return RoutedResponse{}, err
	}
	verbose, err := strconv.Atoi(verboseText)
	if err != nil {
		return RoutedResponse{}, err
	}
	return RoutedResponse{
		ID:        id,
		AccountID: accountID,
		Verbose:   verbose == 1,
	}, nil
}
