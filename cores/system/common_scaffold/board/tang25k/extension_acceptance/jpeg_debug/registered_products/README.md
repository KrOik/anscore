# Registered product JPEG candidate

Development candidate, production baseline untouched. Root owns hardware and formal API owner runs the unique route.

Six 8x8 partial products preserve exact signed24 by signed16 multiplication. Registered radix256 diagonal sums/carries produce signed40 product. Registered16-bit limb sums preserve signed48 accumulator wrap. Rounding writes the same low24 bits using split12-bit carry; saturation tests sign extension. Symbols retain accepted difference/magnitude/category/output pipeline.

Run python -B test_product_regression.py, test_dct_regression.py, test_symbols_regression.py and prepare_debug.py. The existing golden and timeouts are unchanged. DEBUG top is not the delivered API. Sources are frozen in source_manifest.json.
