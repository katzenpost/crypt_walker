
/- work-in-progress attempt to port this Haskell merkle tree to Lean
 https://github.com/kazu-yamamoto/hash-tree/blob/main/Data/HashTree/Internal.hs
-/

import Mathlib.Data.ByteArray
import Mathlib.Data.HashMap
import Init.Data.ToString

import «CryptWalker».hash
import «CryptWalker».nat
import «CryptWalker».hex

instance : BEq ByteArray where
  beq a b := a.data = b.data

/-! Settings for Merkle Hash Trees. -/
structure Settings (α : Type) [Hashable α] where
  hash0 : ByteArray
  hash1 : α → ByteArray
  hash2 : ByteArray → ByteArray → ByteArray

def defaultByteArraySettings : Settings ByteArray :=
  { hash0 := myhash (ByteArray.empty),
    hash1 :=  fun x => myhash (ByteArray.mk #[0x00] ++ x),
    hash2 := fun x y => myhash (ByteArray.mk #[0x01] ++ x ++ y) }

inductive HashTree (α : Type) where
  | empty (hash : ByteArray)
  | leaf (hash : ByteArray) (index : Nat) (value : α)
  | node (hash : ByteArray) (leftIndex : Nat) (rightIndex : Nat) (leftTree : HashTree α) (rightTree : HashTree α)
deriving BEq

def reprIndented {α : Type} [Repr α] (tree : HashTree α) (indent : String) (last : Bool) : String :=
  let newIndent := indent ++ (if last then "   " else "│  ")
  match tree with
  | HashTree.empty hash =>
      s!"{indent}{if last then "└─ " else "├─ "}(empty {repr hash})"
  | HashTree.leaf hash index value =>
      s!"{indent}{if last then "└─ " else "├─ "}(leaf {repr hash}, index: {index}, value: {repr value})"
  | HashTree.node hash leftIndex rightIndex leftTree rightTree =>
      let leftStr := reprIndented leftTree newIndent false
      let rightStr := reprIndented rightTree newIndent true
      s!"{indent}{if last then "└─ " else "├─ "}(node {repr hash}, left index: {leftIndex}, right index: {rightIndex})\n{leftStr}\n{rightStr}"

instance {α : Type} : Inhabited (HashTree α) where
  default := HashTree.empty (ByteArray.mk #[])

structure MerkleHashTrees (α : Type) [Hashable α] :=
  (settings : Settings α)
  (size : Nat)
  (hashtrees : (Lean.HashMap Nat (HashTree α)))
  (indices : (Lean.HashMap ByteArray Nat))

/-! digest gets the current Merkle Tree hash value -/
def digest (α : Type) [Hashable α] (treeSize : Nat) (tree : MerkleHashTrees α) : ByteArray :=
  match Lean.HashMap.findEntry? tree.hashtrees treeSize with
  | .none => panic! "failed to find entry in hash tree"
  | some (_, ht) =>
    match ht with
    | HashTree.empty hash => hash
    | HashTree.leaf hash _ _ => hash
    | HashTree.node hash _ _ _ _ => hash

def index (α : Type) [Hashable α] (tree : MerkleHashTrees α) (hash : ByteArray) : Nat :=
  match Lean.HashMap.findEntry? tree.indices hash with
  | some n => n.snd
  | none => panic! "failed to find tree index"

/-! currentHead returns the current Merkle Tree head -/
def currentHead (α : Type) [Hashable α] (tree : MerkleHashTrees α) : Option (HashTree α):=
  match Lean.HashMap.findEntry? tree.hashtrees tree.size with
  | .none => none
  | some (_, ht) => some ht

/-! info gets the root information of the Merkle Hash tree.
    A pair of the current size and the current Merkle Tree Hash is returned. -/
def info (α : Type) [Hashable α] (tree : MerkleHashTrees α) : (Nat × Option ByteArray) :=
  (tree.size, digest α tree.size tree)

/-! empty creates an empty 'MerkleHashTrees'. -/
def empty (α : Type) [Hashable α] (settings : Settings α) : MerkleHashTrees α :=
  MerkleHashTrees.mk settings 0 (Lean.mkHashMap) (Lean.mkHashMap)

/-! hashValue returns the hash value for the given HashTree. -/
def hashValue (α : Type) [Hashable α] (tree : HashTree α) : ByteArray :=
  match tree with
  | .empty hash => hash
  | .leaf hash _ _ => hash
  | .node hash _ _ _ _=> hash

def rIndex (α : Type) (tree : HashTree α) : Nat :=
  match tree with
  | HashTree.empty _ => panic! "not a node"
  | HashTree.leaf _ index _ => index
  | HashTree.node _ _ index _ _ => index

def lIndex (α : Type) (tree : HashTree α) : Nat :=
  match tree with
  | HashTree.empty _ => panic! "not a node"
  | HashTree.leaf _ index _ => index
  | HashTree.node _ index _ _ _ => index

def isPowerOf2 (n : Nat) : Bool :=
  (n &&& (n - 1)) == 0

/-! add, adds the given input into the tree, returning the new tree.-/
def add (α : Type) [Hashable α] (inp : α) (tree : MerkleHashTrees α) : MerkleHashTrees α :=
  let hx := tree.settings.hash1 inp
  if tree.indices.contains hx then
    tree
  else
    let newSize := tree.size + 1
    let newLeaf := HashTree.leaf hx tree.size inp
    let newHt := match tree.hashtrees.find? tree.size with
      | some ht => insert ht
      | none => newLeaf -- not reached
    let newHashTrees := tree.hashtrees.insert newSize newHt
    let newIndices := tree.indices.insert hx newSize
    { tree with size := newSize, hashtrees := newHashTrees, indices := newIndices }
  where
  insert (ht : HashTree α) : HashTree α :=
    let settings := tree.settings
    let hx := settings.hash1 inp
    let newLeaf := HashTree.leaf hx tree.size inp
    match ht with
    | .empty _ => newLeaf
    | .leaf h idx _ => HashTree.node (settings.hash2 h hx) idx tree.size ht newLeaf
    | .node h leftIdx rightIdx leftTree rightTree =>
    let sz := rightIdx - leftIdx + 1
    if isPowerOf2 sz then
      HashTree.node (settings.hash2 h hx) leftIdx tree.size ht newLeaf
    else
      let newRight := insert rightTree
      let leftHash := hashValue α leftTree
      let rightHash := hashValue α rightTree
      HashTree.node (settings.hash2 leftHash rightHash) leftIdx tree.size leftTree newRight

/-! fromList inserts a list of input items into the tree. -/
def fromList (α : Type) [Hashable α] (settings : Settings α) (xs : List α) : MerkleHashTrees α :=
  xs.foldl (fun acc x => add α x acc) (empty α settings)

structure InclusionProof where
  index : Nat := 0
  treeSize : Nat := 1
  proof : List ByteArray := []
deriving BEq

instance : ToString InclusionProof where
  toString x :=
    let proofLines := (x.proof.foldl fun acc h => acc ++ s!"{h}\n") ""
    s!"InclusionProof index: {x.index} treeSize: {x.treeSize} proof: \n{proofLines}" ++ ""

instance : Inhabited InclusionProof where
  default := { index := 0, treeSize := 0, proof := [] }

def sizeTree (α : Type) [Hashable α] (tree : MerkleHashTrees α) (treeSize : Nat) : (HashTree α) :=
  match tree.hashtrees.find? treeSize with
  | none => panic! "failed to find hash tree entry"
  | .some x => x

def genarateInclusionProof (α : Type) [Hashable α] (targetHash : ByteArray) (treeSize : Nat) (tree : MerkleHashTrees α) : Option InclusionProof :=
  let ht : HashTree α := sizeTree α tree treeSize
  let i := index α tree targetHash
  if i < treeSize then
    let digests := List.reverse $ path i ht
    some { index := i, treeSize := treeSize, proof := digests }
  else
    none
  where
    path (index : Nat) (tree : HashTree α) : List ByteArray :=
      match tree with
      | HashTree.empty _ => []
      | HashTree.leaf _ _ _ => []
      | HashTree.node _ _ _ l r =>
        if index <= rIndex α l then
          hashValue α r :: path index l
        else
          hashValue α l :: path index r



def shiftR1 (p : Nat × Nat) : Nat × Nat :=
  (p.fst >>> 1, p.snd >>> 1)

def untilSet (fst snd : Nat) : Nat × Nat :=
  match fst, snd with
  | 0, _ => (0, snd)
  | f, s => if f % 2 != 0 then (f, s) else untilSet (f >>> 1) (s >>> 1)
  termination_by fst
  decreasing_by
  sorry


def verifyInclusionProof (α : Type) [Hashable α] (settings : Settings α) (leafHash : ByteArray) (rootHash : ByteArray) (proof : InclusionProof) : IO Bool :=
  if proof.index >= proof.treeSize then pure false else
    let rec verify (index treeSize : Nat) (currentHash : ByteArray) (proof' : List ByteArray) : IO Bool := do
      IO.println s!"Verifying: index={index}, treeSize={treeSize}, currentHash={currentHash}"
      match index, treeSize, proof' with
      | _, sn, [] => pure (sn == 0 && currentHash == rootHash)
      | _, 0, _ => pure false
      | index, treeSize, p :: ps =>
        if index % 2 != 0 || index == treeSize then
          let currentHash' := settings.hash2 currentHash p
          let (index', treeSize') := shiftR1 $ untilSet index treeSize
          verify index' treeSize' currentHash' ps
        else
          let currentHash' := settings.hash2 p currentHash
          let (index', treeSize') := shiftR1 (index, treeSize)
          verify index' treeSize' currentHash' ps
    verify proof.index (proof.treeSize - 1) leafHash proof.proof
