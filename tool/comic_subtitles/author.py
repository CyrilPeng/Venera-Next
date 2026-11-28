"""Run from the repository or copy the tool directory to a Windows desktop."""

import argparse
import json
import sys
import zipfile
from importlib.metadata import version
from pathlib import Path

from exchange import import_revision, pack, publish
from project import (ChapterSource, apply_edit, atomic_json, create_project, page_at, project_lock,
                     read_json, recognize, require)
from translation import approve, prepare, provider_payload, receive, send


def arguments():
    parser = argparse.ArgumentParser(description='Local comic OCR and subtitle editor')
    parser.add_argument('project', type=Path, help='local project JSON filename')
    commands = parser.add_subparsers(dest='command', required=True)
    init = commands.add_parser('init')
    init.add_argument('source', type=Path, help='chapter image directory or CBZ')
    init.add_argument('--language', required=True)
    adopt = commands.add_parser('import', help='reopen a published editorial revision as a new project')
    adopt.add_argument('source', type=Path, help='chapter directory or CBZ containing originals')
    adopt.add_argument('--revision', type=Path, help='detached subtitle directory, otherwise use the embedded pair')
    cbz = commands.add_parser('pack', help='flatten a chapter and write a new CBZ')
    cbz.add_argument('destination', type=Path)
    cbz.add_argument('--plain', action='store_true')
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
    batch = commands.add_parser('prepare', help='write text-only translation batches for a language')
    batch.add_argument('target')
    batch.add_argument('output', type=Path)
    batch.add_argument('--page', type=int)
    batch.add_argument('--glossary', type=Path)
    batch.add_argument('--redo', action='store_true')
    reply = commands.add_parser('receive', help='import one batch reply as review candidates')
    reply.add_argument('reply', type=Path)
    review = commands.add_parser('approve', help='confirm one translation, optionally correcting its text')
    review.add_argument('page', type=int)
    review.add_argument('dialogue')
    review.add_argument('batch')
    review.add_argument('--text')
    remote = commands.add_parser('send', help='preview or send one batch to a chat completions endpoint')
    remote.add_argument('batch')
    remote.add_argument('--endpoint', required=True)
    remote.add_argument('--model', required=True)
    remote.add_argument('--allow-endpoint', help='authorize this exact URL after reviewing the preview')
    return parser.parse_args()


def run(args):
    with project_lock(args.project):
        if args.command in ('init', 'import'):
            require(not args.project.exists(), 'Project already exists')
            with ChapterSource(args.source) as source:
                project = create_project(source, args.language) if args.command == 'init' else import_revision(source, args.revision)
                atomic_json(args.project, project)
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
        elif args.command == 'pack':
            pack(project, args.destination, args.plain)
        elif args.command == 'prepare':
            require(not args.output.exists(), 'Choose a new request file')
            batches = prepare(project, args.target, number=args.page, redo=args.redo,
                              glossary=read_json(args.glossary) if args.glossary else None)
            atomic_json(args.project, project)
            atomic_json(args.output, batches)
            print(len(batches), 'batches')
        elif args.command == 'approve':
            approve(project, args.page, args.dialogue, args.batch, args.text)
            atomic_json(args.project, project)
        elif args.command in ('send', 'receive'):
            if args.command == 'send':
                batch = project.get('batches', {}).get(args.batch)
                require(batch is not None, 'Unknown batch')
                if args.allow_endpoint is None:
                    print(args.endpoint, json.dumps(provider_payload(batch, args.model), ensure_ascii=False, indent=2))
                    return 0
                reply, elapsed = send(batch, args.endpoint, args.model, args.allow_endpoint)
                batch['elapsedMs'] = elapsed
            else:
                reply = read_json(args.reply)
            report = receive(project, reply)
            atomic_json(args.project, project)
            print(json.dumps(report))
            return int(bool(report['issues']))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(run(arguments()))
    except (ImportError, ValueError, OSError, KeyError, zipfile.BadZipFile) as error:
        sys.exit(str(error))
