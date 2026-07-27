# S2 Photos round-trip spike — evidence record

Date: 2026-07-27 · Device: iPhone 15 Pro (XDR) · Vehicle: `DeviceSpike/` Probe C ("Run S2 Photos round-trip").

**Question:** does `PHAssetCreationRequest` preserve a dual-dialect (Google XMP +
ISO 21496-1) UltraHDR JPEG, and does Photos render it as HDR? This was the single
most load-bearing unverified assumption in the iOS export story (plan risk #2).

**Method:** bundle `mockups/hdr-samples/p1_uhdr_150.jpg` (19,796,482 bytes, a real
full-res Gainmap export) → save via `PHAssetCreationRequest.forAsset().addResource(
with: .photo, fileURL:)` (`shouldMoveFile = false`) → fetch the created asset →
`PHAssetResourceManager.requestData` on its `.photo` resource → byte-compare +
probe aux data on the round-tripped bytes.

**Result: PASS, strongest outcome.**

```
orig:    19796482 bytes  sha256 fb1c0c28893087a9…
fetched: 19796482 bytes  sha256 fb1c0c28893087a9…   → BYTE-IDENTICAL
ISO 21496-1 gain map on round-tripped bytes: PRESENT
Apple/HDR (legacy) gain map:                 absent (expected — we write XMP+ISO)
Visual check in Photos.app on the XDR screen: highlights visibly glow (Sam, 2026-07-27)
```

**Consequences:**
- P6's export design stands as planned: `PHAssetCreationRequest` + auto-save
  toggle. No share-sheet/Files fallback needed.
- Photos stores the submitted bytes as the original resource without re-encoding;
  the export a user AirDrops or re-shares from Photos is the exact file Gainmap wrote.

**S2 CLOSED 2026-07-27.**
