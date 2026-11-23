# PhotoArchive iPhone design

The approved rebuild uses a native, photo-first interface. This specification applies only to iPhone; the web and Android clients retain their current interfaces.

## Shared system

- System typography with Dynamic Type; system background, secondary background, label and secondary label colors. System blue is the only action accent. Keep the existing app icon.
- Four persistent destinations: 图库, 找照片, 故事, 地图. Settings remain a toolbar destination. Search maintenance lives in a task sheet and settings, separate from results.
- Photos carry the visual hierarchy. Gallery cells are square, three columns with 2-point gutters; accessibility text sizes use two columns. Date headings belong to sections, never repeated below every cell.
- Controls have accessible names and at least 44-point targets. Selected cells announce selection. Loading, unavailable, limited permission, empty and failed states explain a next action without hiding existing content.
- Detail photos fit the available area; editing is presented in native sheets. Navigation and sheet dismissal preserve drafts, selection and gallery position.
- Use system transitions. Reduce Motion removes decorative transitions. No animated progress causes a full gallery refresh.

## Page structure

- Gallery: compact permission status when action is needed, date/type filters and a small anniversary entry above the reusable collection view. Selection actions sit at the bottom.
- Search: query and editable conditions above the same media grid. Certain/possible matches remain distinguishable. Task status opens analysis, download, cloud and usage controls.
- Stories: cover-led list; detail shows title and description above an ordered media grid. A shared paginated picker adds photos to the editor; reorder, cover and undo remain available.
- Map: stable map while clusters refresh; selected region opens the shared media browser. Device location is never requested.
- Settings: photo access, analysis/tasks, account, organization sync, original upload and privacy in native grouped sections. Login alone does not enable upload or AI.

## Verification

Check compact and standard iPhone widths, light/dark appearance, maximum Dynamic Type, VoiceOver labels and Reduce Motion. Functional tests and measured real-device performance are separate gates; mock screenshots are not performance evidence.
