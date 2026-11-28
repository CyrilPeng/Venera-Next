"""Desktop two-pane proofreader. Original images are opened read-only."""

import tkinter as tk
from copy import deepcopy
from tkinter import messagebox, simpledialog, ttk

from PIL import ImageTk

from project import ChapterSource, apply_edit, atomic_json, verified_image


def open_editor(project, project_path):
    root = tk.Tk()
    root.title(project['title'] + ' · 漫画字幕校对')
    page_number = 0
    image_preview = None
    ratio = (1.0, 1.0)
    boxes = []
    start = None
    status = tk.StringVar()
    header = ttk.Frame(root)
    header.pack(fill='x')
    panes = ttk.Panedwindow(root, orient='horizontal')
    panes.pack(fill='both', expand=True)
    canvas = tk.Canvas(panes, width=650, height=650, highlightthickness=0, background='#333')
    side = ttk.Frame(panes)
    panes.add(canvas, weight=1)
    panes.add(side, weight=1)
    listing = tk.Listbox(side, selectmode='extended', exportselection=False, width=42)
    listing.pack(fill='both', expand=True)
    ttk.Label(side, text='拖框调整区域，按 Ctrl 多选可合并。拆分时依读序拖两个框。', wraplength=320).pack()

    def page():
        return project['pages'][page_number]

    def refresh():
        nonlocal image_preview, ratio, start
        start = None
        boxes.clear()
        listing.delete(0, 'end')
        canvas.delete('all')
        with ChapterSource(project['source']) as source, verified_image(source, page()) as image:
            width, height = image.size
            image.thumbnail((650, 650))
            ratio = (image.width / width, image.height / height)
            image_preview = ImageTk.PhotoImage(image)
        canvas.create_image(0, 0, anchor='nw', image=image_preview)
        for raw in page()['observations']:
            canvas.create_polygon([(horizontal * ratio[0], vertical * ratio[1]) for horizontal, vertical in raw['quad']],
                                  fill='', outline='#ffb454')
        for position, item in enumerate(page()['dialogues'], 1):
            scaled = [value * ratio[index % 2] for index, value in enumerate(item['area'])]
            canvas.create_rectangle(*scaled, outline='#47d6ff', width=2)
            canvas.create_text(*scaled[:2], anchor='nw', text=str(position), fill='#0580a5')
            listing.insert('end', f'{position}. {item["text"]}')
        status.set(f'{page_number + 1} / {len(project["pages"])} · {page()["image"]} · {page()["status"]}')

    def move_page(delta):
        nonlocal page_number
        page_number = min(max(0, page_number + delta), len(project['pages']) - 1)
        refresh()

    def drag_start(event):
        nonlocal start
        start = (event.x, event.y)

    def drag_end(event):
        if start is None:
            return
        left, right = sorted((start[0], event.x))
        top, bottom = sorted((start[1], event.y))
        width, height = page()['size']
        box = [max(0, round(left / ratio[0])), max(0, round(top / ratio[1])),
               min(width, round(right / ratio[0])), min(height, round(bottom / ratio[1]))]
        if box[0] < box[2] and box[1] < box[3]:
            boxes.append(box)
            canvas.create_rectangle(left, top, right, bottom, outline='#91ff57', dash=(3, 3))

    def edit(action):
        selected = [page()['dialogues'][index] for index in listing.curselection()]
        operation = dict(op=action)
        if action in ('up', 'down') and len(selected) == 1:
            keys = [item['id'] for item in page()['dialogues']]
            index = keys.index(selected[0]['id'])
            other = index + (-1 if action == 'up' else 1)
            if not 0 <= other < len(keys):
                return
            keys[index], keys[other] = keys[other], keys[index]
            operation = dict(op='order', ids=keys)
        elif action == 'split' and len(selected) == 1 and len(boxes) >= 2:
            parts = []
            for box in boxes[-2:]:
                content = simpledialog.askstring('拆分', f'第 {len(parts) + 1} 句', parent=root)
                if not content:
                    return
                parts.append(dict(area=box, text=content))
            operation.update(id=selected[0]['id'], parts=parts)
        elif ((action == 'add' and boxes) or (action == 'edit' and len(selected) == 1) or
              (action == 'merge' and len(selected) >= 2)):
            initial = '' if action == 'add' else ''.join(item['text'] for item in selected)
            content = simpledialog.askstring('校对', '原文', initialvalue=initial, parent=root)
            if not content:
                return
            operation['text'] = content
            if action == 'merge':
                operation['ids'] = [item['id'] for item in selected]
            if action == 'edit':
                operation['id'] = selected[0]['id']
            if boxes and action != 'merge':
                operation['area'] = boxes[-1]
        else:
            messagebox.showinfo('校对', '请先选中相应对白或拖出所需区域。', parent=root)
            return
        candidate = deepcopy(page())
        try:
            apply_edit(candidate, operation)
            pages = list(project['pages'])
            pages[page_number] = candidate
            atomic_json(project_path, {**project, 'pages': pages})
            project['pages'] = pages
            refresh()
        except (ValueError, OSError) as error:
            messagebox.showerror('校对', str(error), parent=root)

    canvas.bind('<ButtonPress-1>', drag_start)
    canvas.bind('<ButtonRelease-1>', drag_end)
    ttk.Button(header, text='上一页', command=lambda: move_page(-1)).pack(side='left')
    ttk.Button(header, text='下一页', command=lambda: move_page(1)).pack(side='left')
    ttk.Label(header, textvariable=status).pack(side='left')
    for label, action in [('校对原文', 'edit'), ('新增对白', 'add'), ('合并选中', 'merge'),
                          ('拆分对白', 'split'), ('上移', 'up'), ('下移', 'down')]:
        ttk.Button(side, text=label, command=lambda selected=action: edit(selected)).pack(fill='x')
    refresh()
    root.mainloop()
