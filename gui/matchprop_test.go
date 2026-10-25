package main

import (
	"strings"
	"testing"
)

// The fixtures are the real dumps from the reference phones: a Samsung A908N on
// a stock Lineage build (every property says r3q) and a Xiaomi 26012RN62A whose
// vendor property is the shared mivendor and whose build.product is missi. They
// are the two ways the old "ro.product.vendor.device == codename" default went
// wrong: the second one never matches, and a naive vendor pick matches a family.
const (
	a9Values = `[ro.product.brand]: [samsung]
[ro.product.device]: [r3q]
[ro.product.manufacturer]: [samsung]
[ro.product.model]: [SM-A908N]
[ro.product.name]: [lineage_r3q]
[ro.product.odm.device]: [r3q]
[ro.product.odm.name]: [lineage_r3q]
[ro.product.system.device]: [r3q]
[ro.product.system.name]: [r3q]
[ro.product.system_ext.device]: [r3q]
[ro.product.vendor.device]: [r3q]
[ro.product.vendor.name]: [lineage_r3q]
[ro.product.bootimage.device]: [r3q]
[ro.build.product]: [r3q]
`
	a9Labels = `[ro.build.product]: [u:object_r:build_prop:s0]
[ro.product.bootimage.device]: [u:object_r:build_bootimage_prop:s0]
[ro.product.device]: [u:object_r:build_prop:s0]
[ro.product.model]: [u:object_r:build_prop:s0]
[ro.product.name]: [u:object_r:build_prop:s0]
[ro.product.odm.device]: [u:object_r:build_odm_prop:s0]
[ro.product.odm.name]: [u:object_r:build_odm_prop:s0]
[ro.product.system.device]: [u:object_r:build_prop:s0]
[ro.product.system.name]: [u:object_r:build_prop:s0]
[ro.product.system_ext.device]: [u:object_r:build_prop:s0]
[ro.product.vendor.device]: [u:object_r:build_vendor_prop:s0]
[ro.product.vendor.name]: [u:object_r:build_vendor_prop:s0]
`

	redmiValues = `[ro.product.brand]: [Redmi]
[ro.build.product]: [missi]
[ro.product.device]: [zephyr]
[ro.product.manufacturer]: [Xiaomi]
[ro.product.model]: [26012RN62A]
[ro.product.name]: [zephyr_global]
[ro.product.odm.device]: [zephyr]
[ro.product.odm.name]: [zephyr_global]
[ro.product.product.device]: [missi]
[ro.product.system.device]: [generic]
[ro.product.system_ext.device]: [missi]
[ro.product.vendor.device]: [mivendor]
[ro.product.vendor.name]: [mivendor_sm6225_global]
[ro.product.bootimage.device]: [zephyr]
[ro.product.bootimage.name]: [zephyr_global]
[ro.product.vendor.model]: [Xiaomi for arm64]
`
	redmiLabels = `[ro.product.brand]: [u:object_r:build_prop:s0]
[ro.build.product]: [u:object_r:build_prop:s0]
[ro.product.device]: [u:object_r:build_prop:s0]
[ro.product.model]: [u:object_r:build_prop:s0]
[ro.product.name]: [u:object_r:build_prop:s0]
[ro.product.odm.device]: [u:object_r:build_odm_prop:s0]
[ro.product.odm.name]: [u:object_r:build_odm_prop:s0]
[ro.product.product.device]: [u:object_r:build_prop:s0]
[ro.product.system.device]: [u:object_r:build_prop:s0]
[ro.product.system_ext.device]: [u:object_r:build_prop:s0]
[ro.product.vendor.device]: [u:object_r:build_vendor_prop:s0]
[ro.product.vendor.name]: [u:object_r:build_vendor_prop:s0]
[ro.product.bootimage.device]: [u:object_r:build_bootimage_prop:s0]
[ro.product.bootimage.name]: [u:object_r:build_bootimage_prop:s0]
[ro.product.vendor.model]: [u:object_r:build_vendor_prop:s0]
`
)

func rankFixture(t *testing.T, values, labels string) MatchReport {
	t.Helper()
	return rankMatchProps(parseGetprop(values), parseGetpropLabels(labels))
}

// A stock ROM where everything carries the codename: the vendor property wins,
// because it survives a GSI and zygote can read it.
func TestRankMatchPropsStockRom(t *testing.T) {
	rep := rankFixture(t, a9Values, a9Labels)

	if rep.Codename != "r3q" {
		t.Fatalf("codename = %q, want r3q", rep.Codename)
	}
	if rep.Confidence != "high" {
		t.Fatalf("confidence = %q, want high", rep.Confidence)
	}
	if len(rep.Candidates) == 0 || rep.Candidates[0].Prop != "ro.product.vendor.device" {
		t.Fatalf("top candidate = %+v, want ro.product.vendor.device", rep.Candidates)
	}
	if rep.Candidates[0].Value != "r3q" || rep.Candidates[0].Trust != "high" || !rep.Candidates[0].Perfect {
		t.Fatalf("top candidate = %+v", rep.Candidates[0])
	}
	if rep.ModuleProp != "persist.sys.overlay.r3q" {
		t.Fatalf("module property = %q", rep.ModuleProp)
	}
}

// The Redmi is the case the old default got wrong: ro.product.vendor.device is
// mivendor, which is not this phone's name, so it must be ruled out with a
// reason and the readable property that does carry zephyr must win.
func TestRankMatchPropsSharedVendorName(t *testing.T) {
	rep := rankFixture(t, redmiValues, redmiLabels)

	if rep.Codename != "zephyr" {
		t.Fatalf("codename = %q, want zephyr (not mivendor or missi)", rep.Codename)
	}
	// Nothing here satisfies every rule: the vendor value is shared, and the
	// properties that do carry zephyr are either unreadable to zygote (odm,
	// bootimage) or replaced by a GSI (device, name). That must come out as
	// "no perfect pick", not as a confident recommendation.
	if rep.Confidence != "medium" {
		t.Fatalf("confidence = %q, want medium", rep.Confidence)
	}
	top := rep.Candidates[0]
	if top.Prop != "ro.product.device" || top.Value != "zephyr" {
		t.Fatalf("top candidate = %+v, want ro.product.device = zephyr", top)
	}
	if top.Label != "build_prop" || top.Trust != "medium" || top.Perfect {
		t.Fatalf("top candidate label/trust/perfect = %q/%q/%v", top.Label, top.Trust, top.Perfect)
	}
	for _, c := range rep.Candidates {
		if c.Perfect {
			t.Fatalf("a property was called perfect without surviving a GSI or being readable: %+v", c)
		}
	}
	if !strings.Contains(top.Risk, "GSI") {
		t.Fatalf("the /system risk is not explained: %q", top.Risk)
	}

	ruledOut := map[string]string{}
	for _, r := range rep.Rejected {
		ruledOut[r.Prop] = r.Reason
	}
	if !strings.Contains(ruledOut["ro.product.vendor.device"], "shared by many Xiaomi devices") {
		t.Fatalf("mivendor was not ruled out with a reason: %+v", rep.Rejected)
	}
	if ruledOut["ro.product.system.device"] == "" {
		t.Fatalf("generic was not ruled out: %+v", rep.Rejected)
	}
	// The OEM properties that do carry zephyr are kept as alternatives, with
	// the readability risk spelled out rather than hidden.
	var odm *MatchCandidate
	for i := range rep.Candidates {
		if rep.Candidates[i].Prop == "ro.product.odm.device" {
			odm = &rep.Candidates[i]
		}
	}
	if odm == nil {
		t.Fatal("ro.product.odm.device (a GSI survivor) was dropped from the list")
	}
	if odm.Trust != "medium" || !strings.Contains(odm.Risk, "denied to zygote") {
		t.Fatalf("odm candidate = %+v, want medium with the zygote warning", odm)
	}
}

// Nothing usable: a GSI that renamed every identity property and no OEM
// survivor carries a name. The report must say so instead of crowning a guess —
// this is the "stop and show the list" case.
func TestRankMatchPropsNothingConvincing(t *testing.T) {
	values := `[ro.product.brand]: [Xiaomi]
[ro.product.device]: [phh_treble]
[ro.product.manufacturer]: [Xiaomi]
[ro.product.model]: [Pixel 7]
[ro.product.system.device]: [generic]
[ro.product.vendor.device]: [mivendor]
[ro.product.vendor.model]: [Qualcomm SM8550 for arm64]
[ro.build.product]: [treble]
`
	labels := `[ro.product.device]: [u:object_r:build_prop:s0]
[ro.product.model]: [u:object_r:build_prop:s0]
[ro.product.system.device]: [u:object_r:build_prop:s0]
[ro.product.vendor.device]: [u:object_r:build_vendor_prop:s0]
[ro.product.vendor.model]: [u:object_r:build_vendor_prop:s0]
[ro.build.product]: [u:object_r:build_prop:s0]
`
	rep := rankFixture(t, values, labels)

	if rep.Codename != "" {
		t.Fatalf("codename = %q, want none: every candidate is a build name", rep.Codename)
	}
	if rep.Confidence != "low" {
		t.Fatalf("confidence = %q, want low", rep.Confidence)
	}
	if rep.ModuleProp != "" {
		t.Fatalf("module property = %q, want none without a codename", rep.ModuleProp)
	}
	for _, c := range rep.Candidates {
		if c.Trust == "high" {
			t.Fatalf("a guess was marked high: %+v", c)
		}
	}
}

// `adb devices` is not the only adb stream with chatter in it: a ROM can print a
// warning into getprop output too, and a half-parsed line must not become a
// property with a made-up label.
func TestParseGetprop(t *testing.T) {
	out := "warning: something\r\n" +
		"[ro.product.device]: [zephyr]\r\n" +
		"[ro.product.vendor.device]: []\r\n" +
		"not a property line\n"
	props := parseGetprop(out)
	if len(props) != 2 {
		t.Fatalf("parsed %d properties, want 2: %v", len(props), props)
	}
	if props["ro.product.device"] != "zephyr" {
		t.Fatalf("ro.product.device = %q", props["ro.product.device"])
	}
	if v, ok := props["ro.product.vendor.device"]; !ok || v != "" {
		t.Fatalf("empty value was not kept: %q %v", v, ok)
	}
	if shortPropertyLabel("u:object_r:build_vendor_prop:s0") != "build_vendor_prop" {
		t.Fatalf("label was not shortened")
	}
}
