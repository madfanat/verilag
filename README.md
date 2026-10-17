# verilag

__verilag__ is a SystemVerilog implementation of a set-associative cache with LRU and bit bpLRU policies.

## Features

- 8-bit, 16-bit, and 32-bit reads and writes.
- Write-back and write-allocate policies.
- Cache line invalidation.
- LRU replacement using access timestamps.
- bpLRU replacement using one recently-used bit per way.
- Hit and access counters.

## Specifications

| Parameter            | Value                                |
| -------------------- | ------------------------------------ |
| Cache size           | 4 KiB                                |
| Cache line size      | 64 bytes                             |
| Associativity        | 4 ways                               |
| Number of sets       | 16                                   |
| Number of lines      | 64                                   |
| Main memory size     | 128 KiB                              |
| Address width        | 17 bits                              |
| Address layout       | 7-bit tag, 4-bit index, 6-bit offset |
| Data bus width       | 16 bits                              |

- Little-endian byte order.
- CPU requests send the tag and index first, then the byte offset.
- Dirty lines are written back on eviction.
- Invalidation discards a line without writing it back.

### Modules

| Module       | Description                                            |
| ------------ | ------------------------------------------------------ |
| `Cpu`        | Memory requests for matrix multiplication.             |
| `Cache`      | Requests, line fills, write-backs, and replacement.    |
| `Controller` | Byte-addressable main memory and cache line transfers. |
| `testbench`  | Runs replacement policies and prints statistics.       |

## Building and testing

Requirements:

- Icarus Verilog.

Compile and run the simulation:

```sh
iverilog -g2012 -s testbench -o tb.out tb.sv
vvp tb.out
```

Expected output:

| Replacement | Hit rate | Hits    | Accesses |
| ----------- | -------: | ------: | -------: |
| LRU         | 99.4800% | 248302  | 249600   |
| bpLRU       | 99.4631% | 248260  | 249600   |
