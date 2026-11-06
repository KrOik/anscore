# Independently reviewed EOF followup

The initial attempt retained5 successful preparations,3 successful syntax
children,1 successful compile and1 failed tiny simulation. Failure was at the
terminal TB assertion requiring `$fscanf(...,"%d",...)` to return exactly-1 at
the trailing whitespace/EOF boundary. The original vector has no unconsumed
record, and all6 numerical frames reached this assertion. The assertion is not
a numerical or protocol failure, and the failed image/log/receipt remain frozen.

Only the independent followup TB changes that one assertion: `%s` attempts to
read any next token and fails if one is returned. Return0 or-1 signifies no
remaining token. This still rejects numerical or nonnumeric trailing data.
RTL, original TB/runner/plan/gate/receipt and all five vectors are unchanged.

The finite plan contains5 compile/simulation pairs using the new TB, including
the original tiny profile and the four previously unrun profiles. No syntax,
oracle import, numerical preparation, inherited runner/model or hardware check
is repeated. Full source/hash review and a new unique root+peer gate precede
execution. Each child uses20/5/sole2 seconds and failure stops further launches.
