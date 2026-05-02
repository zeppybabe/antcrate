# submodular-scheduler — research

## Purpose

The current AntCrate ingest queue is FIFO with a `priority` field hint. This
works for one or two bundles in flight but degrades when the queue holds 20+
items with mixed priorities, deadlines, and dependency relationships.

This bundle is a literature review for whether a streaming submodular
maximization approach (selecting the next bundle to ingest under a budget
constraint) outperforms naive priority-sort.

## Key references

- Badanidiyuru et al., "Streaming Submodular Maximization" (2014)
- Kazemi et al., "Submodular Streaming in All Its Glory" (2019)
- Mirzasoleiman et al., "Distributed Submodular Maximization" (2016)

PDFs are in `attachments/papers/`.

## What we want from a prototype

1. A scoring function `score(bundle, queue_state)` that captures: priority,
   age, dependency satisfaction, estimated dev cost.
2. A streaming selection algorithm with a known approximation ratio.
3. A simulator using historical AntCrate queue traces (we don't have these
   yet — first dev task is to instrument the queue to record a trace).

## Open questions to answer in implementation

- Is the scoring function actually submodular? (Probably yes for the diversity
  component, no for the dependency component.)
- Can we tolerate the (1 - 1/e) approximation ratio in practice?

## Why "theoretical" type

There is no upstream repo that does exactly this. We're starting from papers
and a blank `~/projects/projects/submodular-scheduler/`. AntCrate just needs
to register an empty project and drop the research/skill into place.
