# Status

PASS: true same-frame EDT-to-Chamfer pipeline, score map and best location. No board validation claimed.

13 main image fixtures pass: embedded exact match, zero-score row-major ties, empty image/template/both, single pixels and thin dimensions, full-size template, random32x32, actual maximum EDT distance1922 with 1x1template, and all64 template edges. Full stored EDT fields and every output score/sum/position/marker/invalid flag are exact against independent 2-D brute force and actual SciPy EDT for valid images.

39 healthy protocol recovery frames pass, including 6 malformed template markers,6 malformed frame markers,6 invalid runtime configurations,17 CE-low reset phases,child/internal failures and coincident last-EDT-value/DONE. Successful frame -> invalid START -> successful frame without reset proves best metadata clears. Five invalid static dimension profiles pass. 192 separate arithmetic-domain tests cover all template edge counts1..64, sum bound123008 and Q8 score492032; these synthetic arithmetic bounds are not misrepresented as geometric images.

Complete flattened hierarchy Gowin synthesis and check -assert pass at7x9,16x16,32x32. Largest profile:758 LUT1..4+39 MUX5+372 ALU=1169 LUT-class primitives; conservatively accounting 68 RAM16SDP4 as272 additional LUT4 equivalents gives1441. 494 FF,2 DPX9B,0 DSP. No blackboxes or estimated component sums are used.

All test commands and semantics are in README. Only this directory changed; the frozen EDT dependency and all baseline artifacts remain untouched. All bulky temporary outputs were automatically cleaned. Network reference attempts are honestly marked unavailable; actual installed SciPy source and numerical execution remain verified references.
