# Source provenance and semantic closure

Baseline:98176a8f970354ebd6191d0370662ab35ff53664. New RTL, independent model,
TB, runner and documentation are independently authored under Apache-2.0.
No shared source is edited, and no upstream code is copied, translated,
imported, built or executed.

Before implementation, read-only official GitHub retrieval resolved
TheSDK-blocks/adc_analyser to commit
`0609f7aa0c95c06e01ca6cb672aba4668d5a8f24`. The inspected source is
[adc_analyser/__init__.py](https://github.com/TheSDK-blocks/adc_analyser/blob/0609f7aa0c95c06e01ca6cb672aba4668d5a8f24/adc_analyser/__init__.py),
and its [LICENSE_AALTO.txt](https://github.com/TheSDK-blocks/adc_analyser/blob/0609f7aa0c95c06e01ca6cb672aba4668d5a8f24/LICENSE_AALTO.txt)
contains the Aalto University2022 copyright and MIT-style permission/warranty
terms. Its algorithm finds transitions in a ramp voltage/code record and
supports endpoint/best-fit INL; this package instead specifies exact finite
occupancy ratios and cropped cumulative endpoints. No upstream bit equivalence
or external runtime dependency is claimed. Raw UTF8 response hashes appear in
references.json. The web tool returned a transport500; direct official HTTPS
read-only retrieval succeeded.

The official ADI article
[Histogram Testing Determines DNL and INL Errors](https://www.analog.com/en/resources/technical-articles/histogram-testing-determines-dnl-and-inl-errors.html)
was read for the measured/ideal histogram ratio, cumulative DNL interpretation
and the need to account for excitation distribution and sample statistics.
Its sine-wave normalization is deliberately not implemented here. The selected
ideal distribution is uniform, with an explicit conditional denominator over
the selected contiguous bins. No article code is incorporated.

Semantic searches used `rg --hidden --no-ignore` across the entire `cores` tree,
including older untracked assets and legacy libraries, for code-density,
DNL/INL, ADC linearity/calibration histograms, transition levels and missing
codes. Actual related RTL/contract inspection found:

|Existing source|Behavior and distinction|
|---|---|
|`img_hist_accumulator.v`|Fixed-record256-bin synchronous histogram/readback; reused unchanged for acquisition. No signed occupancy normalization.|
|`img_hist_ratio_u8.v`|Restricted unsigned floor(255*n/d), n<=d; unsuitable for signed DNL/INL ratios beyond unity.|
|`operator_library/rtl/acc_img_histogram_bin16_update.v`|Packed16-bin update/read/saturation operator; no code-density report or cumulative endpoint normalization.|
|`signal_video/rtl/cip_image_histogram.v`|Frame histogram/HE adapter and packets; no measurement estimator.|
|`transforms/ip/hist256`|Device-oriented code counts/read port; no selected-range arithmetic or transaction result contract.|
|`ks_histogram_distance.sv`|Two weighted distributions and KS extrema; no one-distribution uniform occupancy DNL/INL rows.|
|`recip_div.sv`|Signed RNE fixedpoint divider; inspected, but exact remainder flags are better served by existing integer_divider.|
|`sys_capture_replay.v`|Host-loaded replay/capture; actual trigger window chosen for the measurement composition.|
|HX711/ADS1115 peripheral blocks|ADC interfaces; do not estimate code-density linearity.|

No existing implementation supplied this bounded measured-count-to-signed-
DNL/cumulative-INL function. Generic image histogram/HE/CLAHE and code capture
are retained as separate contracts rather than renamed as new capabilities.

Production closure (all paths are package-root relative in the file lists):

|Source|Role|
|---|---|
|`rtl/adc_code_density.sv`|New selected-range measurement controller.|
|`example/trigger_adc_density256.sv`|New actual trigger+256-sample composition.|
|`../../system/common_scaffold/image/histogram/rtl/img_hist_accumulator.v`|Unchanged acquisition/readback.|
|`../../system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v`|Unchanged shared exact prefix product.|
|`../../acceleration/integer_divider/rtl/integer_divider.v`|Unchanged exact quotient/remainder.|
|`../../system/stream_bus_library/rtl/sys_trigger_window.v`|Unchanged trigger capture/replay.|

The seal binds raw bytes of this complete closure plus TB, model, runner,
fixed-reference metadata and all prerequisite documentation. There are no
includes, coefficients, generated RTL, ROMs or vendor blocks. Only independent
test vectors are generated at qualification runtime. The runner archives all
executed files before preparation; `.gitattributes` is copied as inert
`.gitattributes.executed.txt` data to preserve its bytes without adding a Git
control file. The package's own attributes are exactly `* -text\n`.
