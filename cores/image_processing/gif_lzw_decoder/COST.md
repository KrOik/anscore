# Logical architecture and exact range proof

No physical resource count, frequency, power or hardware service rate has been
measured. The114688-bit logical RAM capacity is fixed by the full GIF dictionary,
not by fixture sizes. Mapping to BRAM/LUTRAM and the controller remain unverified.
Declared scalar storage, including the two memory read-q registers and held
index byte, is187+COUNT_W+TAG_W bits:227 at defaults,251 at32/32,192 at4/1.

One packed4096x20 dictionary stores prefix12/suffix8. One4096x8 reverse stack
stores expanded bytes. Each has one synchronous read OR one write per edge;
all read-q consumption is on a later state. Dictionary reads/writes and stack
reads/writes never overlap within a memory. No asynchronous array read,
RAM reset loop, DSP, multiplier, divider or image frame store is present.

Let b be the minimum code size, c=2^b, and f=c+2. Literal codes0..c-1 are roots;
c and c+1 are control codes. Allocation next is13 bits, representing f..4096.
A data code is a root, allocated code<f_next, or exactly f_next with a previous
word and f_next<4096. Every new prefix is the preceding data code. It is already
allocated or literal and is strictly less than the new entry's address. Thus
every traversed prefix strictly decreases and reaches a literal root. A CLEAR
sets next=f and invalidates previous ownership. Old RAM above that range cannot
be read; each newly valid entry was written in this dictionary generation.

There are4096-f possible nonliteral entries. Inductively the longest word has
at most1+(4096-f)=4095-c bytes, maximized at4091 for b=2. The KwKwK construction
adds exactly one byte to an existing word and writes its new entry before that
code becomes the previous owner. A4096-byte reverse stack is sufficient;
stack_count is13 bits and no valid write uses address4096. A KwKwK push precedes
the reverse expansion, making its extra first byte the final emitted byte.

Code width is4 bits (3..12). After an allocation, new_next equal to2^width
raises the width for the following code. CLEAR itself is fetched before reset;
EOI is fetched at the current width. At next4096 no allocation, width growth
or next increment occurs. The subsequent CLEAR still uses12 bits, then restores
b+1. No read-valid bitmap or4096-entry CLEAR sweep is needed.

The bit reservoir is19 bits. Refilling occurs only with bit_count<width<=12,
so at most11+8=19 bits are live. Extraction consumes the current width before
any control-code action. A CLEAR preserves the residual bits; EOI discards them.
The sub-block countdown is8 bits and represents1..255 while in payload mode.

With no source gaps or consumer stalls, let B be accepted packet bytes including
minimum, lengths, payload and terminator; C the decoded code count including
CLEAR/EOI; P retired indices; K KwKwK codes; and R NEED_CODE refill branches.
For a successful packet, from first-byte acceptance to first completion-valid:

    clocks = (B-1) + 2*C + 6*P - 2*K + R

Each normal word of L bytes takes6L expansion/retirement clocks; KwKwK takes
6L-2. Extraction and dispatch take2 per code. Each accepted later byte takes
one clock. Refill branches takeR separate clocks. Completion backpressure and
all external pauses add arbitrary waits. No frame-rate claim follows from
these paper counts.

For a successful packet stack writes and reads each equalP. Dictionary reads
equal P-U-K, where U counts all data codes, including KwKwK. Dictionary writes
are one per data code with a previous word until capacity is reached in that CLEAR
generation. These counts are fixture-checkable without duplicating RAM timing.
