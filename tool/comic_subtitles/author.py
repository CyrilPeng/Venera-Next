"""Run from the repository or copy the tool directory to a Windows desktop."""

import argparse
import json
import sys
import zipfile
from importlib.metadata import version
from pathlib import Path

from exchange import publish
from project import (ChapterSource, apply_edit, atomic_json, create_project, page_at, project_lock,
                     read_json, recognize, require)


def arguments():
    parser = argparse.ArgumentParser(description='Local comic OCR and subtitle editor')
    parser.add_argument('project', type=Path, help='local project JSON filename')
    commands = parser.add_subparsers(dest='command', required=True)
    init = commands.add_parser('init')
    init.add_argument('source', type=Path, help='chapter image directory or CBZ')
    init.add_argument('--language', required=True)
    ocr = commands.add_parser('ocr', help='process pending/failed pages, checkpoint each page')
    ocr.add_argument('--page', type=int)
    show = commands.add_parser('show', help='inspect page and dialogue IDs')
    show.add_argument('page', type=int)
    edit = commands.add_parser('edit', help='apply editorial operations atomically')
    edit.add_argument('page', type=int)
    edit.add_argument('operations', type=Path)
    commands.add_parser('editor', help='open the desktop correction window')
    export = commands.add_parser('export')
    export.add_argument('directory', type=Path, help='new publication directory')
    return parser.parse_args()


def run(args):
    with project_lock(args.project):
        if args.command == 'init':
            require(not args.project.exists(), 'Project already exists')
            with ChapterSource(args.source) as source:
                atomic_json(args.project, create_project(source, args.language))
            return 0
        project = read_json(args.project)
        require(project.get('version') == 1, 'Unknown author project version')
        if args.command == 'ocr':
            from rapidocr_onnxruntime import RapidOCR
            pages = [page_at(project, args.page)] if args.page is not None else project['pages']
            pending = [page for page in pages if page['status'] in ('pending', 'failed')]
            if pending:
                engine = RapidOCR(intra_op_num_threads=2, inter_op_num_threads=1)
                name = 'rapidocr-onnxruntime/' + version('rapidocr-onnxruntime') + ' PP-OCRv4/ch'
                with ChapterSource(project['source']) as source:
                    for page in pending:
                        recognize(page, source, engine, name)
                        atomic_json(args.project, project)
                        print(page['id'], page['status'], len(page['observations']), page['elapsedMs'], 'ms', flush=True)
            return int(any(page['status'] == 'failed' for page in pages))
        if args.command == 'show':
            print(json.dumps(page_at(project, args.page), ensure_ascii=False, indent=2))
        elif args.command == 'edit':
            for operation in read_json(args.operations):
                apply_edit(page_at(project, args.page), operation)
            atomic_json(args.project, project)
        elif args.command == 'editor':
            from editor import open_editor
            open_editor(project, args.project)
        elif args.command == 'export':
            publish(project, args.directory)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(run(arguments()))
    except (ImportError, ValueError, OSError, KeyError, zipfile.BadZipFile) as error:
        sys.exit(str(error))
