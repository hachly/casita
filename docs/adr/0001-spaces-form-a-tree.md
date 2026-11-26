# Spaces form a tree

All spaces share one fixed-size encrypted store so its size never reveals how many spaces exist, and a space must not know where other spaces keep their data, so something has to hand out room or spaces would overwrite each other's hidden data. We chose a tree: each parent space holds its children's keys and gives each child a share of its own room, and any space can create children inside that share.

## Considered Options

- **Independent spaces, fixed equal shares made at setup**: a forced code exposes only one space, but the number of spaces is fixed, no space can outgrow its share, and the everyday space (which needs many normal photos) runs out first.

## Consequences

- Whoever learns the top space's code can open every space.
- A space's room is bounded by what its parent gave it; it can never see a total or a count of spaces elsewhere.
