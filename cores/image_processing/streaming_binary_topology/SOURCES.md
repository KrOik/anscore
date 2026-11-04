# Sources and license

All local RTL, example, numerical oracle, generated testbench template and
documentation are independently written under the repository Apache-2.0
license. No third-party code is copied or adapted. No third-party include,
ROM, source package or generator is needed offline. Development baseline:
`ba0b98f69397877ed8e0643d0d24cc8bc6da8ce05`.

Predevelopment read-only comparison reviewed this implementation and its
digital-topology connectivity convention:

- Repository: https://github.com/scikit-image/scikit-image
- Fixed release: v0.24.0
- Fixed commit: `a160f384523ac70173d069954b7084bee79fb68e`
- File: `skimage/measure/_regionprops_utils.py`, function `euler_number`
- URL: https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/skimage/measure/_regionprops_utils.py
- Git blob: `f3307d159a9d3b172d41bab82a1cc433495c3ae6`
- Source SHA256: `082e1bc648424c8647edced00562c4bb81da7c5641a3f32c067d7b2f678c3b24`
- License text: https://github.com/scikit-image/scikit-image/blob/a160f384523ac70173d069954b7084bee79fb68e/LICENSE.txt
- License Git blob: `dc6a0f0db801d80daa92cd19ee0b63bf77bed047`
- License SHA256: `51f15344f59759ed5d8ddb6dad48e8b994bdd45b050a80fe58a419bd0f98aed0`
- The actual mixed-license file declares ordinary files copyright 2009-2022
  the scikit-image team, BSD-3-Clause. The inspected measure file has no named
  exception and is covered by that default entry. No upstream source or
  license-bearing file is redistributed here.

The reference documents complementary foreground/background adjacency and a
neighborhood-based Euler calculation. The local implementation independently
uses explicit zero-padded 2x2 contributions and a synchronous single-row
datapath. The independent finite-test oracle deliberately uses connected-region
graph traversal rather than translating the reference implementation or the
hardware table. No direct runtime comparison to an installed scikit-image
package is claimed.

Candidate source and license were retrieved with read-only GitHub API requests.
No upstream scripts, setup/build systems or installation commands were run.
External content was treated only as untrusted reference data. The repository
already contained complete CCA, contours and hole filling; those were retained
unchanged and are not recounted as new capabilities in this package.
