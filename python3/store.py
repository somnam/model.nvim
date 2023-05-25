import zlib
import os
import glob
import json

import sys
import numpy as np
import numpy.typing as npt
import openai
import tiktoken

from typing import TypedDict, Optional, Sequence, List, cast

# TODO make token counting optional
# TODO we probably just want to store the entire files in store.json instead of re-reading them
# TODO all paths relative to store.json

enc = tiktoken.encoding_for_model('gpt-4')

# https://platform.openai.com/docs/api-reference/embeddings/create
INPUT_TOKEN_LIMIT = 8192

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

def tap(x, label: Optional[str] = None):
    if label is not None:
        eprint('<<', label)
    eprint(x)
    if label is not None:
        eprint(label, '>>')
    return x

def count_tokens(text: str) -> int:
    return len(enc.encode(text))

def hash_content(text: str) -> str:
    data = text.encode('utf-8')
    return f'{zlib.adler32(data):08x}'

def normalize_filepath(filepath: str) -> str:
    return filepath.replace('\\', '/')

class Item(TypedDict):
    id: str
    content: str
    meta: Optional[dict] # NotRequired not supported

class StoreItem(Item):
    embedder: str
    content_hash: str

class Store(TypedDict):
    abs_path: str
    items: list[StoreItem]
    vectors: npt.NDArray[np.float32] | None

def load_or_initialize_store (store_dir: str) -> Store:
    # TODO should I write store on load if it doesn't exist?
    def initialize_empty_store (abs_path) -> Store:
        return {
            'abs_path': abs_path,
            'items': [],
            'vectors': np.array([])
        }

    abs_path = os.path.abspath(os.path.join(store_dir, '.llm_store.json'))

    try:
        with open(abs_path, encoding='utf-8') as f:
            store_raw = json.loads(f.read()) 
            store: Store = {
                'abs_path': abs_path,
                'items': store_raw['items'],
                'vectors': np.array(store_raw['vectors'])
            }

            return store

    except FileNotFoundError:
        return initialize_empty_store(abs_path)

def save_store(store: Store):
    if store['vectors'] is None: return

    store_raw = {
        'items': store['items'],
        'vectors': [ v.tolist() for v in store['vectors'] ]
    }

    with open(store['abs_path'], mode='w', encoding='utf-8') as f:
        f.write(json.dumps(store_raw))

def ingest_files(root_dir, glob_pattern) -> list[Item]:
    "Ingest files down from root_dir assuming utf-8 encoding. Skips files which fail to decode."

    def ingest_file(filepath: str) -> Optional[Item]:
        with open(filepath, mode='r') as f:
            try:
                return {
                    'id': normalize_filepath(filepath),
                    'content': f.read(),
                    'meta': {
                        'type': 'file'
                    }
                }
            except:
                return None

    def glob_files():
        return [
            normalize_filepath(path) for path in
                glob.glob(os.path.join(root_dir, glob_pattern), recursive=True)
            if os.path.isfile(path)
        ]

    return [ f for f in map(ingest_file, tap(glob_files())) if f ]

def get_embeddings(inputs: list[str], print_token_counts=True):
    if not inputs: return []

    input_tokens = [ (count_tokens(input), input) for input in inputs ]

    if print_token_counts:
        eprint([ (x[1][:30], x[0]) for x in input_tokens ])

    if all(limit[0] < INPUT_TOKEN_LIMIT for limit in input_tokens):
        response = openai.Embedding.create(input=inputs, model="text-embedding-ada-002")
        return [item['embedding'] for item in response['data']]
    else:
        over_limits = [limit[1][:30] for limit in input_tokens if not limit[0] < INPUT_TOKEN_LIMIT]
        eprint('Input(s) over the token limit:')
        eprint(over_limits)
        raise ValueError('Embedding input over token limit')

def get_stale_or_new_item_idxs(items: Sequence[StoreItem], store: Store):
    id_to_content_hash = {x['id']: x['content_hash'] for x in store['items'] }

    return [
        idx for idx, item in enumerate(items) if
            item['id'] not in id_to_content_hash
            or item['content_hash'] != id_to_content_hash[item['id']]
    ]

def get_removed_item_store_idx(items: Sequence[StoreItem], store: Store):
    current_ids = set([item['id'] for item in items])

    return [
        idx
        for idx, item in enumerate(store['items'])
        if item['id'] not in current_ids
    ]

def as_store_items(items: Sequence[Item]) -> List[StoreItem]:
    "Mutates Item seq to StoreItem list in place"
    items = cast(List[StoreItem], items)

    for item in items:
        item['content_hash'] = hash_content(item['content'])
        item['embedder'] = 'openai_ada_002'

    return items

def update_store(
    items: Sequence[Item],
    store: Store,
    sync: bool
) -> list[str]:
    """
    Update stale store data returning updated item ids. sync=True removes any items in store that aren't in provided items.
    For partial updates (only adding items), set sync=False.
    """

    items = as_store_items(items)

    needs_update_idx = get_stale_or_new_item_idxs(items, store)

    if len(needs_update_idx) == 0:
        eprint('all ' + str(len(items)) + ' were stale')
        return []

    needs_update_content = [ items[idx]['content'] for idx in needs_update_idx ]

    embeddings = get_embeddings(needs_update_content)

    if store['vectors'] is None:
        vector_dimensions = len(embeddings[0])
        store['vectors'] = np.empty([0, vector_dimensions], dtype=np.float32)

    assert store['vectors'] is not None

    if sync:
        idxs = get_removed_item_store_idx(items, store)
        for idx in idxs:
            del store['items'][idx]
            np.delete(store['vectors'], idx, axis=0)

    id_to_idx = { item['id']: idx for idx, item in enumerate(store['items']) }

    for i, embedding in enumerate(embeddings):
        item_idx = needs_update_idx[i]
        item = items[item_idx]
        # NOTE pretty sure mutation here has no consequences?

        if item['id'] in id_to_idx:
            idx = id_to_idx[item['id']]

            store['items'][idx] = item
            store['vectors'][idx] = np.array(embedding).astype(np.float32)
        else:
            store['items'].append(item)
            store['vectors'] = np.vstack((store['vectors'], embedding))

    return [ items[idx]['id'] for idx in needs_update_idx ]

def update_store_and_save(items, store, sync=False):
    updated = update_store(items, store, sync)

    if len(updated) > 0:
        save_store(store)

    return updated

def update_with_files_and_save(store, files_root=None, files_glob=None, sync=False):
    return update_store_and_save(
        ingest_files(
            files_root or '.',
            files_glob or '**/*'
        ),
        store,
        sync=sync
    )

def query_store(prompt: str, count: int, store: Store, filter=None):
    assert store['vectors'] is not None

    embedding = get_embeddings([prompt], print_token_counts=False)[0]
    query_vector = np.array(embedding, dtype=np.float32)
    similarities = np.dot(store['vectors'], query_vector.T)
    ranks = np.argsort(similarities)[::-1]

    if filter is None:
        return [ store['items'][idx] for idx in ranks[:count] ]
    else:
        results = []

        for idx in ranks:
            item = store['items'][idx]

            if filter(item):
                results.append(item)

            if len(results) >= count:
                break

        return results
