# SchedSim - CPU Scheduling Simulator

This project is an x86-64 GNU Assembly implementation of a CPU scheduling simulator for the CMPE 230 Systems Programming course.

The program reads a single input line from standard input, parses the selected scheduling algorithm and process list, simulates the CPU execution cycle by cycle, and prints the resulting execution timeline.

## About the Project

SchedSim supports five CPU scheduling algorithms:

* First Come First Serve (FCFS)
* Shortest Job First (SJF)
* Shortest Remaining Time First (SRTF)
* Priority First (PF)
* Round Robin (RR)

Each character in the output represents one CPU cycle. A process ID letter shows which process is running, while `X` represents an idle CPU cycle.

## Features

* Written fully in x86-64 GNU Assembly
* Uses Linux system calls directly
* Does not rely on the C standard library
* Parses input from `stdin`
* Writes output to `stdout`
* Simulates scheduling cycle by cycle
* Supports idle CPU cycles with `X`
* Includes a Makefile-based build system

## Project Structure

```text
.
├── README.md
├── Makefile
└── src
    └── schedsim.s
```

## Supported Algorithms

### FCFS - First Come First Serve

Processes are scheduled according to their arrival time. Once a process starts running, it continues until completion.

Input format:

```text
FCFS <ID>-<BurstTime>-<ArrivalTime> ...
```

Example:

```text
FCFS A-3-1 B-2-2
```

Output:

```text
XAAABB
```

### SJF - Shortest Job First

All processes are assumed to arrive at time 0. The process with the shortest burst time is selected first. It is non-preemptive.

Input format:

```text
SJF <ID>-<BurstTime> ...
```

Example:

```text
SJF A-2 B-1 C-4
```

Output:

```text
BAACCCC
```

### SRTF - Shortest Remaining Time First

SRTF is the preemptive version of SJF. At each clock cycle, the ready process with the shortest remaining time is selected.

Input format:

```text
SRTF <ID>-<BurstTime>-<ArrivalTime> ...
```

Example:

```text
SRTF A-4-0 B-2-1 C-5-0
```

Output:

```text
ABBAAACCCCC
```

### PF - Priority First

Processes are selected according to priority. A lower priority number means higher priority. The algorithm is preemptive.

Input format:

```text
PF <ID>-<BurstTime>-<ArrivalTime>-<Priority> ...
```

Example:

```text
PF A-2-0-2 B-5-1-1
```

Output:

```text
ABBBBBA
```

### RR - Round Robin

Processes are executed cyclically with a fixed quantum. If a process finishes before its quantum expires, the remaining cycles in that quantum are represented with `X`.

Input format:

```text
RR <ID>-<BurstTime> ... <Quantum>
```

Example:

```text
RR A-3 B-4 C-2 2
```

Output:

```text
AABBCCAXBB
```

## How to Build

Use the included Makefile:

```bash
make
```

This assembles and links the program using `as` and `ld`, then creates an executable named:

```text
schedsim
```

## How to Run

After building, run:

```bash
./schedsim
```

Then provide one scheduling input line, for example:

```text
FCFS A-3-1 B-2-2
```

The program prints the execution timeline:

```text
XAAABB
```

You can also run it with input redirection:

```bash
./schedsim < input.txt
```

## Makefile Commands

Build the executable:

```bash
make
```

Run available test case files, if a `test-cases/` folder exists:

```bash
make testcases
```

Remove generated executable and output files:

```bash
make clean
```

## Implementation Notes

The simulator is implemented directly in assembly. It uses static memory areas for process data, input/output buffers, and the Round Robin queue.

The implementation stores process information in parallel arrays:

* process IDs
* burst times
* arrival times
* remaining times
* priorities

The scheduler fills an output buffer with the execution timeline and writes it to standard output using Linux syscalls.

## Course Context

This project was implemented for CMPE 230 - Systems Programming.

The main goal was to practice low-level programming concepts such as assembly syntax, direct syscalls, register usage, memory layout, parsing, control flow, and CPU scheduling algorithms.
