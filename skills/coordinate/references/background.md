# Background and examples

```
User
 └─ Coordinator            ← you
     ├─ Architect::<area>  ← one per initiative (/architect)
     │   └─ workers        ← Herdr panes, one worktree each
     └─ …
```

(idle baseline for `sysctl kern.num_files` is about 57k open files, most of it the Colima VM)
