# Provenance and offline closure

New RTL, wrapper, model, testbench and documentation are original ANSCORE work
under Apache-2.0; the local LICENSE applies. No third-party RTL, trained model,
weights, binary or generated table is adopted.

Read-only discovery on2026-11-07 (Asia/Shanghai):

- Neural Discrete Representation Learning, arXiv1711.00937:
  https://arxiv.org/abs/1711.00937 . The abstract was fetched with HTTP200.
  It motivates discrete learned representations using vector quantization;
  this package supplies integer code selection/reconstruction only.
- GitHub repository search for vector quantization FPGA found VQ4SNN:
  https://github.com/ic-lab-duth/VQ4SNN at commit
  a63f65a9c76b5b93b04ba99089fe5aac8223d935 . The pinned README and LICENSE were
  fetched read-only with HTTP200. The inspected MIT license is copyright2026
  Integrated Circuits Lab @ DUTH. Its model-specific SNN inference and weight
  codebook storage are outside this standalone query-engine boundary. No
  upstream source or model is copied or run.

The web connector returned HTTP500. Discovery used bounded read-only native
HTTP requests; no downloaded build, installer or script was executed.

The core has no external source or initialization dependency. The example
references ../int4_weight_matvec/rtl/deps/stream_requantize.v, an unchanged
existing canonical exact-byte alias already committed before this batch.
Its Apache-2.0 provenance and source hashes will be pinned with the final
finite plan. No mature dependency will be modified or historical validation
adopted. Codebook values are supplied through the documented configuration
interface; no network connection or mandatory generator is needed to use RTL.
