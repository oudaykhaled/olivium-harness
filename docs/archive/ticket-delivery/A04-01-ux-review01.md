# A04-01 UX review

Static inspection only; audit pins inputs. No rendered, mobile, runtime or accessibility-conformance claim. **Changes requested:** terminology obscures separate save actions; disabled Continue remains the sole primary-styled action during editing.

Apply these 12 copy replacement blocks at the pinned source lines. Preserve IDs, events, command values, and guards.

1. L342: “Choose your company context and sources for a harness. Save notes and choices separately. Later steps are not available here yet.”
2. L382 button: “Save note”.
3. L383 button: “Save choices”.
4. L380: “Save note saves only this note. Save choices saves only the selections. Save all changes before continuing. Limit: 2,048 bytes per note.”
5. L264 notices, respectively: “Note saved. Changed choices still need Save choices.” / “Choices saved. Edited notes still need Save note.”
6. L296–299 statuses, respectively: “Saved records match this setup” / “Choose the required records” / “Some saved records have changed” / “Could not check saved choices”.
7. L300–304 reasons, respectively: “Choose a company profile, project, repository and assigned goal, then Save choices.” / “Choose a source collection and saved coverage revision, then Save choices.” / “Your choices are saved. Continue opens the next step.” / “Review changed or unavailable choices before continuing. Use Back to update earlier choices.” / “This step is not available here yet. You can use the separate workflows below.”
8. L370: “Measurement status: unknown. The saved goal records your intent; results have not been measured here.”
9. L371: “Saving these choices clears later source choices in this setup. Company records stay unchanged.”
10. L376: “Saved source choices do not confirm that sources are complete or up to date.”
11. L388–390 heading, paragraph, corpus-link label: “This step is not available here yet” / “Your setup is saved. Opening this step does not start analysis, review, building, task checks or release. Use the separate workflows below.” / “Review current sources”.
12. L70: “Save your note and choices before navigating. Back and Continue do not save changes.”

Presentation suggestion (classes only): connected conflict or unavailable read → Reload; otherwise changed selection tokens with available choices → Save choices; otherwise edited note → Save note; otherwise clean, admissible Continue → Continue. Give only that enabled action primary styling. Incomplete input may have none. Preserve handlers, disabling and admission; no combined save. Keep technical details collapsed and the corpus link’s current destination/freshness checks.
