
(*
copyright (c) 2013, simon cruanes
all rights reserved.

redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)


(** {1 Levenshtein distance} *)

module NDA = struct
  type 'a char =
    | Any
    | Char of 'a
  type 'a transition =
    | Success
    | Upon of 'a char * int * int
    | Epsilon of int * int

  (* non deterministic automaton *)
  type 'a t = {
    compare : 'a -> 'a -> int;
    matrix : 'a transition list array array;
  }

  let length nda = Array.length nda.matrix

  let get_compare nda = nda.compare

  let rec mem_tr ~compare tr l = match tr, l with
    | _, [] -> false
    | Success, Success::_ -> true
    | Epsilon (i,j), Epsilon(i',j')::_ -> i=i' && j=j'
    | Upon (Any,i,j), Upon(Any,i',j')::_ when i=i' && j=j' -> true
    | Upon (Char c,i,j), Upon(Char c',i',j')::_
        when compare c c' = 0 && i=i' && j=j' -> true
    | _, _::l' -> mem_tr ~compare tr l'

  (* build NDA from the "get : int -> 'a" function *)
  let make ~compare ~limit ~len ~get =
    let m = Array.make_matrix (len+1) (limit+1) [] in
    let add_transition i j tr =
      if not (mem_tr ~compare tr m.(i).(j))
        then m.(i).(j) <- tr :: m.(i).(j)
    in
    (* internal transitions *)
    for i = 0 to len-1 do
      for j = 0 to limit do
        (* correct char *)
        add_transition i j (Upon (Char (get i), i+1, j));
        (* other transitions *)
        if j < limit then begin
          (* substitution *)
          add_transition i j (Upon (Any, i+1, j+1)); 
          (* deletion in indexed string *)
          add_transition i j (Upon (Any, i, j+1));
          (* addition to indexed string *)
          add_transition i j (Epsilon (i+1, j+1));
        end
      done
    done;
    for j = 0 to limit do
      (* deletions at the end *)
      if j < limit
        then add_transition len j (Upon (Any, len, j+1));
      (* win in any case *)
      add_transition len j Success;
    done;
    { matrix=m; compare; }

  let get nda (i,j) =
    nda.matrix.(i).(j)

  let is_final nda (i,j) =
    List.exists
      (function Success -> true | _ -> false)
      (get nda (i,j))
end

(** deterministic automaton *)
module DFA = struct
  type 'a t = {
    compare : 'a -> 'a -> int;
    mutable transitions : ('a * int) list array;
    mutable is_final : bool array;
    mutable otherwise : int array;  (* transition by default *)
    mutable len : int;
  }

  let create ~compare size = {
    compare;
    len = 0;
    transitions = Array.make size [];
    is_final = Array.make size false;
    otherwise = Array.make size ~-1;
  }

  let _double_array ~init a =
    let a' = Array.make (2 * Array.length a) init in
    Array.blit a 0 a' 0 (Array.length a);
    a'

  (* add a new state *)
  let add_state dfa =
    let n = dfa.len in
    (* resize *)
    if n = Array.length dfa.transitions then begin
      dfa.transitions <- _double_array ~init:[] dfa.transitions;
      dfa.is_final <- _double_array ~init:false dfa.is_final;
      dfa.otherwise <- _double_array ~init:~-1 dfa.otherwise;
    end;
    dfa.len <- n + 1;
    n

  let rec __mem_tr ~compare tr l = match tr, l with
    | _, [] -> false
    | (c,i), (c',i')::l' ->
        (i=i' && compare c c' = 0)
        || __mem_tr ~compare tr l'

  (* add transition *)
  let add_transition dfa i tr =
    if not (__mem_tr ~compare:dfa.compare tr dfa.transitions.(i))
      then dfa.transitions.(i) <- tr :: dfa.transitions.(i)

  let add_otherwise dfa i j =
    dfa.otherwise.(i) <- j

  let set_final dfa i =
    dfa.is_final.(i) <- true

  (* set of pairs of ints: used for representing a set of states of the NDA *)
  module NDAStateSet = Set.Make(struct
    type t = int * int
    let compare = Pervasives.compare
  end)

  let set_to_string s =
    let b = Buffer.create 15 in
    Buffer.add_char b '{';
    NDAStateSet.iter
      (fun (x,y) -> Printf.bprintf b "(%d,%d)" x y)
      s;
    Buffer.add_char b '}';
    Buffer.contents b

  (* list of characters that can specifically be followed from the given set *)
  let chars_from_set nda set =
    NDAStateSet.fold
      (fun state acc ->
        let transitions = NDA.get nda state in
        List.fold_left
          (fun acc tr -> match tr with
            | NDA.Upon (NDA.Char c, _, _) ->
                if List.exists (fun c' -> nda.NDA.compare c c' = 0) acc
                then acc
                else c :: acc (* new char! *)
            | _ -> acc
          ) acc transitions
      ) set []

  (* saturate current set w.r.t epsilon links *)
  let saturate_epsilon nda set =
    let q = Queue.create () in
    NDAStateSet.iter (fun s -> Queue.push s q) set;
    let set = ref set in
    while not (Queue.is_empty q) do
      let state = Queue.pop q in
      (*Printf.printf "saturate epsilon: add state %d,%d\n" (fst state)(snd state);*)
      set := NDAStateSet.add state !set;
      List.iter
        (fun tr' -> match tr' with
          | NDA.Epsilon (i,j) -> 
              if not (NDAStateSet.mem (i,j) !set)
                then Queue.push (i,j) q
          | _ -> ()
        ) (NDA.get nda state)
    done;
    !set

  (* find the transition that matches the given char (if any), or "*";
     may raise exceptions Not_found or LeadToSuccess. *)
  let rec get_transition_for_char nda c acc transitions =
    match transitions with
    | NDA.Upon (NDA.Char c', i, j) :: transitions' when nda.NDA.compare c c' = 0 ->
        (* follow same char *)
        let acc = NDAStateSet.add (i, j) acc in
        get_transition_for_char nda c acc transitions'
    | NDA.Upon (NDA.Any, i, j) :: transitions' ->
        (* follow '*' *)
        let acc = NDAStateSet.add (i,j) acc in
        get_transition_for_char nda c acc transitions'
    | _ :: transitions' -> get_transition_for_char nda c acc transitions'
    | [] ->  acc

  let rec get_transitions_for_any nda acc transitions =
    match transitions with
    | NDA.Upon (NDA.Char _, i, j) :: transitions' ->
        get_transitions_for_any nda acc transitions'
    | NDA.Upon (NDA.Any, i, j) :: transitions' ->
        let acc = NDAStateSet.add (i,j) acc in
        get_transitions_for_any nda acc transitions'
    | _:: transitions' -> get_transitions_for_any nda acc transitions'
    | [] -> acc

  (* follow transition for given NDA.char, returns a new state
     and a boolean indicating whether it's final *)
  let follow_transition nda set c =
    let set' = NDAStateSet.fold
      (fun state acc ->
        let transitions = NDA.get nda state in
        (* among possible transitions, follow the one that matches c
           the most closely *)
        get_transition_for_char nda c acc transitions
      ) set NDAStateSet.empty
    in
    let set' = saturate_epsilon nda set' in
    let is_final = NDAStateSet.exists (NDA.is_final nda) set' in
    set', is_final

  let follow_transition_any nda set =
    let set' = NDAStateSet.fold
      (fun state acc ->
        let transitions = NDA.get nda state in
        (* among possible transitions, follow the ones that are labelled with "*" *)
        get_transitions_for_any nda acc transitions
      ) set NDAStateSet.empty
    in
    let set' = saturate_epsilon nda set' in
    let is_final = NDAStateSet.exists (NDA.is_final nda) set' in
    set', is_final

  (* call [k] with every [transition'] that can be reached from [set], with
     a bool that states whether it's final *)
  let iterate_transition_set nda set k =
    (*Printf.printf "iterate_transition at set %s\n" (set_to_string set);*)
    (* all possible "fixed char" transitions *)
    let chars = chars_from_set nda set in
    List.iter
      (fun c ->
        (*Printf.printf "iterate_transition follows %c (at %s)\n"
          (Obj.magic c) (set_to_string set);*)
        let set', is_final = follow_transition nda set c in
        if not (NDAStateSet.is_empty set')
          then k ~is_final (NDA.Char c) set';
      ) chars;
    (* remaining transitions, with only "Any" *)
    (*Printf.printf "iterate transition follows * (at %s)\n" (set_to_string set);*)
    let set', is_final = follow_transition_any nda set in
    if not (NDAStateSet.is_empty set')
      then k ~is_final NDA.Any set'

  module StateSetMap = Map.Make(NDAStateSet)

  (* get the state that corresponds to the given set of NDA states.
    [states] is a map [nda set] -> [nfa state] *)
  let get_state dfa states set =
    try StateSetMap.find set !states
    with Not_found ->
      let i = add_state dfa in
      states := StateSetMap.add set i !states;
      i

  (* traverse the NDA. Currently we're at [set] *)
  let rec traverse nda dfa states set =
    let set_i = get_state dfa states set in
    iterate_transition_set nda set
      (fun ~is_final c set' ->
        (*Printf.printf "traverse %s --%c--> %s\n" (set_to_string set)
          (match c with NDA.Char c' -> Obj.magic c' | NDA.Any -> '*')
          (set_to_string set');*)
        let set_i' = get_state dfa states set' in
        (* did we reach success? *)
        if is_final
          then set_final dfa set_i';
        (* link set -> set' *)
        match c with
        | NDA.Char c' ->
            add_transition dfa set_i (c', set_i');
            traverse nda dfa states set'
        | NDA.Any ->
            add_otherwise dfa set_i set_i';
            traverse nda dfa states set'
      )

  let of_nda nda =
    let compare = NDA.get_compare nda in
    let dfa = create ~compare (NDA.length nda) in
    (* map (set of NDA states) to int (state in DFA) *)
    let states = ref StateSetMap.empty in
    (* traverse the NDA to build the NFA *)
    let set = NDAStateSet.singleton (0,0) in
    let set = saturate_epsilon nda set in
    traverse nda dfa states set;
    (*StateSetMap.iter
      (fun set i ->
        Printf.printf "set %s --> state %d\n" (set_to_string set) i
      ) !states;*)
    dfa

  let get dfa i =
    dfa.transitions.(i)

  let otherwise dfa i =
    dfa.otherwise.(i)

  let is_final dfa i =
    dfa.is_final.(i)
end

let debug_print oc dfa =
  Printf.fprintf oc "automaton of %d states\n" dfa.DFA.len;
  for i = 0 to dfa.DFA.len-1 do
    let transitions = DFA.get dfa i in
    if DFA.is_final dfa i
      then Printf.fprintf oc "  success %d\n" i;
    List.iter
      (fun (c, j) -> Printf.fprintf oc "  %d --%c--> %d\n" i c j ) transitions;
    let o = DFA.otherwise dfa i in
    if o >= 0
      then Printf.fprintf oc "  %d --*--> %d\n" i o
  done

type 'a automaton = 'a DFA.t

let of_array ?(compare=Pervasives.compare) ~limit a =
  let nda = NDA.make ~compare ~limit ~len:(Array.length a) ~get:(Array.get a) in
  let dfa = DFA.of_nda nda in
  dfa

let of_list ?compare ~limit l =
  of_array ?compare ~limit (Array.of_list l)

let of_string ~limit a =
  let compare = Char.compare in
  let nda = NDA.make ~compare ~limit ~len:(String.length a) ~get:(String.get a) in
  (*debug_print_nda stdout nda;
  flush stdout;*)
  let dfa = DFA.of_nda nda in
  dfa

type match_result =
  | TooFar
  | Distance of int

exception FoundDistance of int

let rec __find_char ~compare c l = match l with
  | [] -> raise Not_found
  | (c', next) :: l' ->
      if compare c c' = 0
      then next
      else __find_char ~compare c l'

(* transition for [c] in state [i] of [dfa];
  @raise Not_found if no transition matches *)
let __transition dfa i c =
  let transitions = DFA.get dfa i in
  try
    __find_char ~compare:dfa.DFA.compare c transitions
  with Not_found ->
    let o = DFA.otherwise dfa i in
    if o >= 0
      then o
      else raise Not_found

(* real matching function *)
let __match ~len ~get dfa =
  let rec search i state =
    (*Printf.printf "at state %d (dist %d)\n" i dist;*)
    if i = len
    then DFA.is_final dfa state
    else begin
      (* current char *)
      let c = get i in
      try
        let next = __transition dfa state c in
        search (i+1) next
      with Not_found -> false
    end
  in
  search 0 0

let match_with dfa a =
  __match ~len:(Array.length a) ~get:(Array.get a) dfa

let match_with_string dfa s =
  __match ~len:(String.length s) ~get:(String.get s) dfa

(** {6 Index for one-to-many matching} *)

(** Continuation list *)
type 'a klist =
  [
  | `Nil
  | `Cons of 'a * (unit -> 'a klist)
  ]

let rec klist_to_list = function
  | `Nil -> []
  | `Cons (x,k) -> x :: klist_to_list (k ())

module Index(X : Map.OrderedType) = struct
  type key = X.t

  module M = Map.Make(X)

  type 'b t =
    | Node of 'b option * 'b t M.t

  let empty = Node (None, M.empty)

  let is_empty = function
    | Node (None, m) -> M.is_empty m
    | _ -> false

  let () = assert (is_empty empty)

  (** get/add/remove the leaf for the given array.
      the continuation k takes the leaf, and returns a leaf option
      that replaces the old leaf. 
      This function returns the new trie. *)
  let goto_leaf ~len ~get node k =
    (* insert the value in given [node], assuming the current index
      in [arr] is [i]. [k] is given the resulting tree. *)
    let rec goto node i rebuild = match node with
      | _ when i = len ->
          let node' = k node in
          rebuild node'
      | Node (opt, m) ->
          let c = get i in
          let t' =
            try M.find c m
            with Not_found -> empty
          in
          goto t' (i+1)
            (fun t'' ->
              if is_empty t''
                then rebuild (Node (opt, M.remove c m))
                else rebuild (Node (opt, M.add c t'' m)))
    in
    goto node 0 (fun t -> t)

  let __add ~len ~get trie value =
    goto_leaf ~len ~get trie
      (function
        | Node (_, m) -> Node (Some value, m))

  let __remove ~len ~get trie value =
    goto_leaf ~len ~get trie
      (function
        | Node (_, m) -> Node (None, m))

  (* traverse the automaton and the idx, yielding a klist of values *)
  let __retrieve dfa idx =
    (* traverse at index i in automaton, with
        [fk] the failure continuation *)
    let rec traverse node i ~(fk:unit->'a klist) =
      match node with
      | Node (opt, m) ->
          (* all alternatives: continue exploring [m], or call [fk] *)
          let fk =
            M.fold
              (fun c node' fk ->
                try
                  let next = __transition dfa i c in
                  (fun () -> traverse node' next ~fk)
                with Not_found -> fk)
              m fk
          in
          match opt with
          | Some v when DFA.is_final dfa i ->
              (* yield one solution now *)
              `Cons (v, fk)
          | _ -> fk ()   (* fail... or explore subtrees *)
    in
    traverse idx 0 ~fk:(fun () -> `Nil)

  let add idx arr value =
    __add ~len:(Array.length arr) ~get:(Array.get arr) idx value

  let remove idx arr value =
    __remove ~len:(Array.length arr) ~get:(Array.get arr) idx value

  let retrieve ~limit idx arr =
    let automaton = of_array ~compare:X.compare ~limit arr in
    __retrieve automaton idx

  let of_list l =
    List.fold_left
      (fun acc (arr,v) -> add acc arr v)
      empty l

  let __to_list ~of_list idx =
    let rec explore acc trail node = match node with
      | Node (opt, m) ->
          (* first, yield current value, if any *)
          let acc = match opt with
            | None -> acc
            | Some v -> (of_list (List.rev trail), v) :: acc
          in
          M.fold
            (fun c node' acc -> explore acc (c::trail) node')
            m acc
    in
    explore [] [] idx

  let to_list idx =
    __to_list ~of_list:Array.of_list idx
end

module StrIndex = struct
  include Index(Char)

  let add_string idx str value =
    __add ~len:(String.length str) ~get:(String.get str) idx value

  let remove_string idx str value =
    __remove ~len:(String.length str) ~get:(String.get str) idx value

  let retrieve_string ~limit idx str =
    let automaton = of_string ~limit str in
    __retrieve automaton idx

  let of_str_list l =
    List.fold_left
      (fun acc (str,v) -> add_string acc str v)
      empty l

  let to_str_list idx =
    (* clumsy conversion [char list -> string] *)
    let of_list l =
      let s = String.make (List.length l) ' ' in
      List.iteri (fun i c -> s.[i] <- c) l;
      s
    in
    __to_list ~of_list idx
end
