package main

// ============================================================================
// Which property should the submitted overlay match on?
// ============================================================================
// A static RRO for the overlay repo matches with android:requiredSystemProperty
// Name/Value, compared with plain string equality. Getting it wrong is silent:
// the overlay installs, `cmd overlay list` shows it enabled, and nothing changes.
//
// Two things decide whether a candidate works, and both are readable from the
// phone without root:
//
//   * zygote has to be able to read the property. A zygote overlay is matched
//     while zygote preloads the framework, so a property in a SELinux area
//     zygote is denied reads as empty and the condition never holds. `getprop -Z`
//     prints the area (build_prop and build_vendor_prop are the safe ones,
//     build_odm_prop and build_bootimage_prop are the usual traps).
//   * the value has to name this device and survive what is installed. The
//     vendor, odm and bootimage partitions keep the OEM value under a GSI;
//     /system, /product and /system_ext are replaced, so ro.product.device on a
//     GSI holds the GSI's own name (phh_treble, mivendor, …).
//
// Neither rule alone is enough — on a GSI the surviving property is often the
// one zygote cannot read, and the readable one has been renamed — so this ranks
// every candidate, says what each one is gambling on, and refuses to call a
// winner when no property actually carries the codename. The values below are
// what the reference phones report: Samsung SM-A908N (everything is r3q) and
// Xiaomi 26012RN62A (ro.product.device is zephyr, but its vendor property is the
// shared mivendor and build.product is missi).

import (
	"regexp"
	"sort"
	"strings"
)

// What a codename looks like: lower case, no separators bash would eat, short
// enough to be a name rather than a build string.
var codenameShape = regexp.MustCompile(`^[a-z][a-z0-9_]{1,23}$`)

// MatchCandidate is one property the submission could be matched on.
type MatchCandidate struct {
	Prop  string `json:"prop"`
	Value string `json:"value"`
	Score int    `json:"score"`
	Zone  string `json:"zone"`
	Label string `json:"label"`
	Trust string `json:"trust"` // high, medium, low
	// Perfect means this is a pick nothing has to be argued about: the value
	// is the codename, zygote can read the property, and a GSI leaves it alone.
	// Only a perfect pick is offered as the answer; anything less and the card
	// tells the user to keep the match they already have.
	Perfect bool   `json:"perfect"`
	Why     string `json:"why"`
	Risk    string `json:"risk,omitempty"`
}

// MatchRejection is a property with a device-ish name that was ruled out, and
// why. The reasons are the answers to the question users ask most often, so
// they are part of the answer rather than something to work out again.
type MatchRejection struct {
	Prop   string `json:"prop"`
	Value  string `json:"value"`
	Reason string `json:"reason"`
}

// MatchReport is what the Config tab shows: the codename it settled on, the
// ranked candidates, the properties it refused, and how sure it is.
type MatchReport struct {
	Serial     string           `json:"serial"`
	Model      string           `json:"model"`
	Codename   string           `json:"codename"`
	Confidence string           `json:"confidence"` // high, medium, low
	ModuleProp string           `json:"moduleProp"`
	Candidates []MatchCandidate `json:"candidates"`
	Rejected   []MatchRejection `json:"rejected"`
}

// matchProp is one entry of the fixed candidate list. zone says which partition
// the value comes from (that is what decides GSI survival) and kind says what
// the property holds.
type matchProp struct {
	name string
	zone string
	kind string
}

var matchPropCandidates = []matchProp{
	{"ro.product.vendor.device", "vendor", "device"},
	{"ro.product.odm.device", "odm", "device"},
	{"ro.product.bootimage.device", "bootimage", "device"},
	{"ro.product.device", "system", "device"},
	{"ro.product.product.device", "product", "device"},
	{"ro.product.system.device", "system", "device"},
	{"ro.product.system_ext.device", "system_ext", "device"},
	{"ro.build.product", "build", "device"},
	{"ro.product.vendor.name", "vendor", "name"},
	{"ro.product.odm.name", "odm", "name"},
	{"ro.product.bootimage.name", "bootimage", "name"},
	{"ro.product.name", "product", "name"},
	{"ro.product.vendor.model", "vendor", "model"},
	{"ro.product.model", "product", "model"},
}

// zoneScore: vendor/odm/bootimage keep the OEM value when a GSI replaces
// /system; a `ro.product.*` value is whatever is installed now.
var zoneScore = map[string]int{
	"vendor": 40, "odm": 35, "bootimage": 35,
	"product": 25, "system": 22, "system_ext": 18, "build": 10,
}

var kindScore = map[string]int{"device": 25, "name": 12, "model": 15}

// labelScore: what the SELinux area means for zygote reading it. The negative
// numbers are the documented traps, not guesses — build_bootimage_prop and
// build_odm_prop are refused to zygote on most GSI builds.
var labelScore = map[string]int{
	"build_prop":           30,
	"build_vendor_prop":    30,
	"vendor_default_prop":  25,
	"default_prop":         15,
	"build_system_prop":    -20,
	"build_odm_prop":       -35,
	"build_bootimage_prop": -35,
	"bootloader_prop":      -20,
}

// Values that name a build rather than a device. They are the reason a "looks
// like a codename" filter is not enough: mivendor is a Xiaomi vendor tree shared
// by a whole family, generic is the GSI itself, qcom is a SoC vendor.
var genericMatchValues = map[string]string{
	"generic":        "the AOSP/GSI build name, shared by every generic image",
	"generic_x86":    "the AOSP/GSI build name, shared by every generic image",
	"generic_arm64":  "the AOSP/GSI build name, shared by every generic image",
	"generic_x86_64": "the AOSP/GSI build name, shared by every generic image",
	"aosp":           "an AOSP build name, not a device",
	"aosp_arm64":     "an AOSP build name, not a device",
	"mainline":       "the mainline/module build name, not a device",
	"treble":         "the Treble build name, not a device",
	"phh_treble":     "the GSI's own name — present on every device running that GSI",
	"mivendor":       "Xiaomi's vendor build name — shared by many Xiaomi devices, not a codename",
	"emulator":       "an emulator, not a phone",
	"unknown":        "no value",
	"qcom":           "a SoC vendor, shared by every Qualcomm device",
	"mediatek":       "a SoC vendor, shared by every MediaTek device",
	"mtk":            "a SoC vendor, shared by every MediaTek device",
	"exynos":         "a SoC vendor, shared by every Exynos device",
	"android":        "not a device name",
}

// rankMatchProps turns a phone's `getprop` and `getprop -Z` output into ranked
// candidates. Both maps are keyed by property name; a missing value or label is
// simply an empty string, because adb output loses lines on some ROMs.
func rankMatchProps(values, labels map[string]string) MatchReport {
	report := MatchReport{
		Candidates: []MatchCandidate{},
		Rejected:   []MatchRejection{},
	}

	brand := strings.ToLower(strings.TrimSpace(values["ro.product.brand"]))
	manufacturer := strings.ToLower(strings.TrimSpace(values["ro.product.manufacturer"]))
	report.Model = strings.TrimSpace(values["ro.product.model"])

	// Phase 1: what is this phone called? Partition order is the rule, not a sum:
	// vendor, odm and bootimage are the OEM's own naming and are what a GSI leaves
	// alone, while /system, /product and /system_ext hold the ROM's name (on a
	// GSI that is the GSI itself: generic, phh_treble, mivendor). A value the OEM
	// partitions agree on is the codename; the later props are only consulted
	// when those are empty or generic.
	codenameOrder := []string{
		"ro.product.vendor.device",
		"ro.product.odm.device",
		"ro.product.bootimage.device",
		"ro.product.device",
		"ro.product.system.device",
		"ro.product.product.device",
		"ro.product.system_ext.device",
		"ro.build.product",
	}
	codename := ""
	codenameProp := ""
	for _, name := range codenameOrder {
		value := strings.TrimSpace(values[name])
		if value == "" || genericMatchValues[strings.ToLower(value)] != "" {
			continue
		}
		if !codenameShape.MatchString(value) {
			continue
		}
		if value == brand || value == manufacturer {
			continue
		}
		codename, codenameProp = value, name
		break
	}
	report.Codename = codename

	// Phase 2: rank every property against that answer.
	for _, p := range matchPropCandidates {
		value := strings.TrimSpace(values[p.name])
		if value == "" {
			continue
		}
		label := shortPropertyLabel(labels[p.name])
		if reason := genericMatchValues[strings.ToLower(value)]; reason != "" {
			report.Rejected = append(report.Rejected, MatchRejection{
				Prop: p.name, Value: value, Reason: reason,
			})
			continue
		}
		if brand != "" && strings.EqualFold(value, brand) {
			report.Rejected = append(report.Rejected, MatchRejection{
				Prop: p.name, Value: value,
				Reason: "the brand, not the device — it would match every phone of this make",
			})
			continue
		}

		c := MatchCandidate{
			Prop:  p.name,
			Value: value,
			Zone:  p.zone,
			Label: label,
		}
		c.Score = zoneScore[p.zone] + kindScore[p.kind] + labelScore[label]

		var why, risk []string
		switch p.zone {
		case "vendor", "odm", "bootimage":
			why = append(why, "lives on /"+p.zone+", which a GSI leaves alone")
		default:
			why = append(why, "read from the installed /"+p.zone+" partition")
			risk = append(risk, "a GSI replaces /"+p.zone+", so the value changes and the match stops")
		}
		switch label {
		case "build_prop", "build_vendor_prop", "vendor_default_prop", "default_prop":
			why = append(why, "zygote can read "+label)
		case "":
			risk = append(risk, "this ROM did not report its SELinux area, so readability is unchecked")
		default:
			risk = append(risk, label+" is often denied to zygote — the overlay can show as enabled and do nothing")
		}
		if codename != "" && value == codename {
			c.Score += 30
			why = append(why, "holds the codename")
			if p.name == codenameProp {
				c.Score += 10
			}
		} else if codename != "" && strings.Contains(value, codename) {
			c.Score += 10
			why = append(why, "contains the codename")
		} else {
			// The missi case: a property that names this build, not this phone.
			// Matching on it would claim a different device, so every such row
			// ranks below the ones that carry the codename.
			c.Score -= 20
			if p.kind == "device" {
				risk = append(risk, "holds a different name ("+value+") than this phone's codename ("+codename+")")
			} else {
				risk = append(risk, "does not hold the codename, so it names this variant rather than the device")
			}
		}
		if codenameShape.MatchString(value) {
			c.Score += 10
		} else {
			c.Score -= 5
			if strings.ContainsRune(value, ' ') {
				risk = append(risk, "contains a space — exact matching works, but it is easy to break while editing")
			}
		}
		if strings.Contains(strings.ToLower(value), "global") {
			c.Score -= 10
			risk = append(risk, "has a region suffix, so another region's build would not match")
		}
		if p.zone == "system" && strings.HasSuffix(p.name, ".device") && value == codename && label == "build_prop" {
			// This is the normal, good answer on a stock ROM: say so instead of
			// making the user read the /system risk as a deal-breaker.
			risk = []string{"if a GSI is installed later this property becomes the GSI's name"}
		}

		c.Why = strings.Join(why, " · ")
		c.Risk = strings.Join(risk, " · ")
		c.Perfect = codename != "" && value == codename && p.kind == "device" &&
			readableByZygote(label) && survivesGSI(p.zone)
		switch {
		case c.Perfect:
			c.Trust = "high"
		case value == codename:
			c.Trust = "medium"
		default:
			c.Trust = "low"
		}
		report.Candidates = append(report.Candidates, c)
	}

	sort.SliceStable(report.Candidates, func(i, j int) bool {
		a, b := report.Candidates[i], report.Candidates[j]
		if a.Score != b.Score {
			return a.Score > b.Score
		}
		// Same score: the one that actually carries the codename is the more
		// useful row, and after that the order only has to be stable.
		if (a.Value == codename) != (b.Value == codename) {
			return a.Value == codename
		}
		return a.Prop < b.Prop
	})

	// Confidence is about the answer, not the ranking. "high" is reserved for a
	// property that satisfies every rule at once (readable by zygote, carries the
	// codename, survives a GSI); anything less and the honest advice is to keep
	// the match that already works, because a submitted condition that does not
	// hold is invisible.
	report.Confidence = "low"
	if len(report.Candidates) > 0 {
		top := report.Candidates[0]
		switch {
		case top.Perfect:
			report.Confidence = "high"
		case top.Value == codename && codename != "":
			report.Confidence = "medium"
		}
	}
	if codename != "" {
		report.ModuleProp = "persist.sys.overlay." + strings.ToLower(codename)
	}
	return report
}

// survivesGSI: a property in these areas keeps the OEM value after a GSI flash.
func survivesGSI(zone string) bool {
	switch zone {
	case "vendor", "odm", "bootimage":
		return true
	}
	return false
}

func readableByZygote(label string) bool {
	switch label {
	case "build_prop", "build_vendor_prop", "vendor_default_prop", "default_prop":
		return true
	}
	return false
}

// shortPropertyLabel turns "u:object_r:build_vendor_prop:s0" into
// "build_vendor_prop", which is the part that means something here.
func shortPropertyLabel(label string) string {
	parts := strings.Split(strings.TrimSpace(label), ":")
	if len(parts) >= 3 {
		return parts[2]
	}
	return ""
}

// parseGetprop reads `getprop` output: one `[key]: [value]` per line. Lines that
// do not fit are skipped — some ROMs print warnings into the same stream.
func parseGetprop(out string) map[string]string {
	props := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r")
		key, rest, ok := strings.Cut(line, "]: [")
		if !ok || !strings.HasPrefix(key, "[") || !strings.HasSuffix(rest, "]") {
			continue
		}
		props[strings.TrimSpace(strings.TrimPrefix(key, "["))] = strings.TrimSuffix(rest, "]")
	}
	return props
}

// parseGetpropLabels reads `getprop -Z`: `[key]: [u:object_r:xyz_prop:s0]`.
func parseGetpropLabels(out string) map[string]string {
	return parseGetprop(out)
}
