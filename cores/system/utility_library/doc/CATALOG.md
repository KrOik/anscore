# IP catalog

| ID | Family | Core | Exact function |
|---|---|---|---|
| 01 | arithmetic | [uadd_carry32](../ip/uadd_carry32/SPEC.md) | Unsigned a+b; result=low32, aux=carry. |
| 02 | arithmetic | [usub_borrow32](../ip/usub_borrow32/SPEC.md) | Unsigned a-b modulo 2^32; aux=(a<b). |
| 03 | arithmetic | [sadd_overflow32](../ip/sadd_overflow32/SPEC.md) | Signed a+b modulo 2^32; aux=signed overflow. |
| 04 | arithmetic | [ssub_overflow32](../ip/ssub_overflow32/SPEC.md) | Signed a-b modulo 2^32; aux=signed overflow. |
| 05 | arithmetic | [absdiff32](../ip/absdiff32/SPEC.md) | Unsigned absolute difference; aux=(a<b). |
| 06 | arithmetic | [minmax_signed32](../ip/minmax_signed32/SPEC.md) | Signed minimum of a,b in result; maximum in aux. |
| 07 | arithmetic | [clamp_signed32](../ip/clamp_signed32/SPEC.md) | Clamp signed a into signed [b,c]; aux=clipped. b>c faults with result=0. |
| 08 | arithmetic | [round_shift_even32](../ip/round_shift_even32/SPEC.md) | Unsigned right shift by b (0..31), ties to even; aux=discarded bits. Invalid shift faults. |
| 09 | bitops | [popcount32](../ip/popcount32/SPEC.md) | Number of set bits in a (0..32). |
| 10 | bitops | [clz32](../ip/clz32/SPEC.md) | Leading zero count in a, including clz(0)=32. |
| 11 | bitops | [ctz32](../ip/ctz32/SPEC.md) | Trailing zero count in a, including ctz(0)=32. |
| 12 | bitops | [bitreverse32](../ip/bitreverse32/SPEC.md) | Reverse all 32 bits of a. |
| 13 | bitops | [byte_reverse32](../ip/byte_reverse32/SPEC.md) | Reverse the order of the four bytes in a. |
| 14 | bitops | [rotate32](../ip/rotate32/SPEC.md) | Rotate a by b[4:0]; c[0]=0 left, 1 right. |
| 15 | bitops | [bitfield_extract32](../ip/bitfield_extract32/SPEC.md) | Extract c bits at bit offset b, c=0..32; require b+c<=32, b<=31. aux=mask. |
| 16 | bitops | [bitfield_insert32](../ip/bitfield_insert32/SPEC.md) | Insert low c[13:8] bits of b into a at c[5:0]; require offset<32,width<=32,offset+width<=32. aux=destination mask. |
| 17 | coding | [gray_decode32](../ip/gray_decode32/SPEC.md) | Decode the 32-bit reflected Gray code a to binary. |
| 18 | coding | [thermometer_decode32](../ip/thermometer_decode32/SPEC.md) | Decode low contiguous ones; result=ones count. Holes fault, with result=0. |
| 19 | coding | [bcd8_encode](../ip/bcd8_encode/SPEC.md) | Unsigned binary a<=99999999 to eight packed decimal digits; out-of-range faults. |
| 20 | coding | [bcd8_decode](../ip/bcd8_decode/SPEC.md) | Eight packed decimal digits a to binary; any nibble>9 faults with result=0. |
| 21 | coding | [hamming13_encode8](../ip/hamming13_encode8/SPEC.md) | SECDED code: 8 data bits a[7:0] in positions 3,5,6,7,9,10,11,12; even parity at 1,2,4,8; overall parity at 13. Position 1 is result bit0. |
| 22 | coding | [hamming13_decode8](../ip/hamming13_decode8/SPEC.md) | Decode low13 a. aux[0]=corrected, aux[1]=uncorrectable, aux[7:4]=syndrome. Double errors, impossible syndrome, or high input bits fault; result=0 on fault. No claim for >=3 flips. |
| 23 | coding | [crc16_poly1021_byte](../ip/crc16_poly1021_byte/SPEC.md) | CRC update: state a[15:0], byte b[7:0], MSB-first, polynomial 0x1021; no initial/final xor. |
| 24 | coding | [crc8_poly07_byte](../ip/crc8_poly07_byte/SPEC.md) | CRC update: state a[7:0], byte b[7:0], MSB-first, polynomial 0x07; no initial/final xor. |
| 25 | packet | [internet_checksum_word](../ip/internet_checksum_word/SPEC.md) | Ones-complement sum of a[15:0], b[15:0]; result=folded sum, aux=complement. Words supplied in host numeric order. |
| 26 | packet | [sequence_window32](../ip/sequence_window32/SPEC.md) | delta=(a-b) modulo 2^32, aux[0]=delta<c and delta<2^31, aux[1]=delta==0. c>=2^31 faults. |
| 27 | packet | [address_boundary4k](../ip/address_boundary4k/SPEC.md) | a=address,b=positive byte length. result=bytes until 4K boundary; aux[0]=crosses boundary, aux[1]=32-bit address wrap. b=0 faults. |
| 28 | packet | [burst_split4k](../ip/burst_split4k/SPEC.md) | a=address,b=remaining positive bytes,c=positive maximum chunk; result=min(b,c,bytes until4K), aux=b-result. Zero lengths fault. |
| 29 | packet | [keep_compact4](../ip/keep_compact4/SPEC.md) | Compact bytes of a selected by b[3:0], lowest lane first; result packed bytes, aux=selected byte count. |
| 30 | packet | [byte_lane_merge4](../ip/byte_lane_merge4/SPEC.md) | Merge a and b under c[3:0] byte write enables (1 selects b). aux=expanded mask. |
| 31 | packet | [leb128_encode28](../ip/leb128_encode28/SPEC.md) | Unsigned a<2^28 to minimal LEB128, low output byte first; aux=byte count (1..4). Wider inputs fault. |
| 32 | packet | [leb128_decode4](../ip/leb128_decode4/SPEC.md) | Decode b=1..4 low bytes of a, require canonical minimal unsigned LEB128 with terminal continuation=0; unused bytes ignored. aux=length. Malformed input faults with result=aux=0. |
| 33 | diagnostics | [walking_pattern32](../ip/walking_pattern32/SPEC.md) | a=bit index 0..31, b[0]=0 walking1,1 walking0; result=pattern, aux=next index. Invalid index faults. |
| 34 | diagnostics | [march_step32](../ip/march_step32/SPEC.md) | a=observed word,b=phase0..5,c=address. March C- micro-step: w0,r0w1,r1w0,r0w1,r1w0,r0. result=write data; aux[0]=write,aux[1]=compare,aux[2]=descending,aux[31:3]=c low29. Compare mismatch faults; this is a micro-step, not a RAM controller. |
| 35 | diagnostics | [stuck_fault32](../ip/stuck_fault32/SPEC.md) | a=observed,b=expected,c=care mask; result=observed0/expected1 bits, aux=observed1/expected0 bits; fault=any mismatch. |
| 36 | diagnostics | [parity_lane32](../ip/parity_lane32/SPEC.md) | result[3:0]=even parity of each byte in a; compare to b[3:0] when c[0]=1, aux=mismatching lanes, fault=any mismatch. |
| 37 | diagnostics | [redundancy_compare32](../ip/redundancy_compare32/SPEC.md) | result=bitwise majority of a,b,c; aux=bits where replicas disagree; fault=any disagreement. Does not assert TMR physical fault tolerance. |
| 38 | diagnostics | [range_guard32](../ip/range_guard32/SPEC.md) | Unsigned a in inclusive [b,c]; result=a if valid else0; aux[0]=below,aux[1]=above,aux[2]=invalid bounds; faults on any violation. |
| 39 | diagnostics | [onehot_guard32](../ip/onehot_guard32/SPEC.md) | a must have exactly one bit set unless c[0] permits zero. result=bit index or32 for zero; aux=population count; fault on violation. |
| 40 | diagnostics | [change_detect32](../ip/change_detect32/SPEC.md) | Accepted-word change detector: result=a XOR previous, aux=new a. c[31] restarts previous=0. |
| 41 | stream | [stream_prefix_sum32](../ip/stream_prefix_sum32/SPEC.md) | Accepted-beat prefix sum of a modulo2^32; aux=carry on this addition; c[31] restarts sum=0. |
| 42 | stream | [stream_running_min32](../ip/stream_running_min32/SPEC.md) | Unsigned accepted-beat minimum; aux=number of beats modulo2^32; c[31] starts a new run. First beat always selects a. |
| 43 | stream | [stream_running_max32](../ip/stream_running_max32/SPEC.md) | Unsigned accepted-beat maximum; aux=number of beats modulo2^32; c[31] starts a new run. |
| 44 | stream | [stream_delta32](../ip/stream_delta32/SPEC.md) | Accepted-word delta a-previous modulo2^32; aux=previous; c[31] restarts previous=0. |
| 45 | stream | [stream_xor_acc32](../ip/stream_xor_acc32/SPEC.md) | Accepted-beat XOR accumulator; aux=previous accumulator; c[31] restarts accumulator=0. |
| 46 | stream | [stream_sequence32](../ip/stream_sequence32/SPEC.md) | Check accepted a against expected sequence. Expected starts at b after reset or c[31]; every beat next expected=a+1. result=next expected,aux=prior expected,fault=mismatch. |
| 47 | stream | [stream_rising_edges32](../ip/stream_rising_edges32/SPEC.md) | Accepted-word rising bits result=a AND NOT previous; aux=falling bits; c[31] restarts previous=0. |
| 48 | stream | [stream_credit32](../ip/stream_credit32/SPEC.md) | Credit ledger: add a then spend b; c[31] resets credit=0. On 33-bit add overflow or insufficient credit, fault and preserve old credit. result=credit,aux=spent (0 on fault). |
| 49 | control | [event_counter32](../ip/event_counter32/SPEC.md) | Add popcount(a AND b) into saturating event counter; aux=this beat count; fault=saturation. c[31] restarts counter=0. |
| 50 | control | [sticky_event32](../ip/sticky_event32/SPEC.md) | Sticky bitmap: result=(previous AND NOT b) OR a; set dominates clear; aux=newly set bits; c[31] restarts previous=0. |
| 51 | control | [first_fault32](../ip/first_fault32/SPEC.md) | Latch first nonzero a as fault code and corresponding b timestamp until c[31] restart; result=latched code,aux=timestamp. |
| 52 | control | [watermark32](../ip/watermark32/SPEC.md) | Accepted-word unsigned high watermark; aux=current a; c[31] restarts high=0. |
| 53 | control | [hysteresis32](../ip/hysteresis32/SPEC.md) | a=unsigned sample,b=low,c[30:0]=high,c[31]=restart to0. State goes1 when a>=high,0 when a<=low; middle holds. b>=high faults and preserves state. result=state,aux=changed. |
| 54 | control | [debounce_word32](../ip/debounce_word32/SPEC.md) | a=candidate word,b=number of identical accepted samples (1..65535),c[31]=restart. result=stable word,aux=current run length capped at65535. Invalid b faults and preserves state. Reset stable=0; qualified candidate replaces stable. |
| 55 | control | [token_bucket32](../ip/token_bucket32/SPEC.md) | Accepted-beat tokens: refill a, cost b, capacity c[30:0],c[31]=restart. Saturate refill at capacity; grant if cost fits. result=remaining tokens,aux=granted,fault=denied. |
| 56 | control | [round_robin8](../ip/round_robin8/SPEC.md) | a[7:0]=requests,b[7:0]=enable mask,c[31]=restart pointer0. result=onehot grant,aux=grant index or8 if none. Pointer advances only on nonzero grant. |
