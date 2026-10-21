# Retained unsupported-contract test

`tb_cip_dma_stubs.v` is the historical regression for the original all-reject
DMA scaffold. Its checks are intentionally retained and have not been rewritten
to accept the new transfers. It must not be used against the completed DMA RTL:
the old contract (every command is UNSUPPORTED and no bus activity) was retired.

The replacement group regression is `tb_cip_dma_e2e.v`. Earlier build directories
still hold the original unsupported-contract results and their source hashes.
