# Serial rotation configuration candidate

Mapper remains exact board-proven affine_v4 SHA74999c4b7f1f1f1c629521f75e105af3a4b3d8d653ca2f639cd4b6bde35b7489 (affine25/perspective264/scale240enabledcycles). Only cip_image_rotate_angle_frame.v additionally changes, with private signed32xunsigned17 CSA serial multiplier embedded after the public module; no new source dependencies. Six products calculate cosine/sine norm and centered inverse offsets.17CSA iterations+7byte-fold iterations preserve exact49-bit signed products. Three-input offset/norm additions use registered byte carry compression. No64-bit combinational multiply/add chain remains.

Dimensions, support, and coefficient range failures still return explicit config error immediately. Valid-range angle/norm and offset checks run after captured arithmetic. Accepted valid configuration to underlying core handshake increases1to29enabledcycles (+28), with unchanged ready/valid/CE freeze semantics. All original numerical goldens and error codes retained.

Seven normal/fault/watchdog UART cases and original14-profile rotation suite PASS:5304commands107240outputs30resets. Exact matrix multiplication supplemental60000product checks inherited unchanged. OSS attempt rotate_config_serial_20261019 running. No production files/JTAG modified by this agent. Failed v3-v6 route evidence retained. Temporary fixtures/binaries auto-cleaned; hold remains unqualified.

Final OSS attempt rotate_config_serial_20261019: placement/route53.21/59.02MHz, 12191LUT4/5523FF/6BRAM/0DSP. All setup/resource/route gates PASS; no explicit hold violations; hold UNPROVEN causes builder exit1. Root owns actual board programming. No production files or JTAG modified by this agent.
