# Provenance and offline source closure

Original ANSCORE Apache-2.0 RTL, wrapper, independent model, tests and docs.
The finite runner adapts the repository's own B41 runner under the same license.
No external code was copied, translated, imported, installed or executed.
External comments/docs were treated only as untrusted technical input.

Read-only fixed official reference:
https://github.com/QuantConnect/Lean/tree/06eb5cb315c7265e00fd2c3c0eda1caef697e637

| Exact file | Bytes | SHA256 |
| --- | ---: | --- |
| Common/Securities/SecurityHolding.cs |17875|6a9b7ca65ba354c751afdb7c4ce149f69d89d10c886642bf1311ae9ccafcf249|
| Common/Securities/BuyingPowerModel.cs |29527|70447794a729be06c0b84db827647fcaec217b05ac3c43a5d51a279d05f12ecd|
| LICENSE |10737|522cf0a716ce03f67d46f8fceb5bf78c5b84400ec5cd8d14bf9f02cddc1cb6ba|

Read the relevant exact source sections: SecurityHolding.Quantity explicitly
distinguishes positive long from negative short, and SetHoldings updates quantity
after portfolio fills (lines109..127,418..438). BuyingPowerModel's margin remaining
depends on direction/current holdings and its HasSufficientBuyingPowerForOrder
uses the unfilled fraction of a ticket (lines179..214,246..324); reserved buying
power for positions is computed separately (lines544..563). Read the complete
191-line Apache-2.0 license, including redistribution/attribution and patent terms.
All file bytes were hashed from the fixed GitHub API contents. This software is
a decimal/margin/portfolio implementation, not this core's two endpoint rule.
The integer two-sided reservation algorithm is original bounded hardware and
does not claim behavioral equivalence to Lean. Its source is a technical
comparison only, with no offline/runtime dependency.

The web tool transport returned HTTP500; direct raw HTTPS had transient SSL EOF.
Fixed official GitHub API contents succeeded with exact byte hashes above.
No external download/cache persisted and no upstream program was run.

Unchanged baseline2e7a6fb51f32e525c1026c28d1f2f45e36545ebc dependencies:

- ../../system/common_scaffold/memory/src/cip_sync_sp_ram.v
- ../ram_ordered_dictionary/rtl/ram_ordered_dictionary.sv
- ../price_level_order_book/rtl/price_level_order_book.sv
- ../../acceleration/price_level_ioc_matcher/rtl/price_level_ioc_matcher.sv

`files.f` needs only the core and shared RAM. `example/files.f` adds the actual
book/dictionaries/matcher and wrapper. All paths resolve relative to this package
root. No includes, ROM images, vendor primitives, online generators or network
access are needed. Exact source/dependency/tool hashes are in FINITE_PLAN.json;
the reviewed runner archives these files and plan before calling the oracle.
All local files have byte-preserving `* -text`; archived `.gitattributes` content
is renamed `.gitattributes.executed.txt` to avoid changing archive interpretation.
