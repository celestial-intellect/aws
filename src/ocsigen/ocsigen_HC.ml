open Lwt
open Ocsigen_http_frame


type headers = (string * string) list
type request_body =  [ `InChannel of int * Lwt_io.input_channel
                     | `None
                     | `String of string ]

exception Http_error of (int * headers * string)

let extract_headers frame =
  let headers = Ocsigen_http_frame.Http_header.get_headers frame.frame_header in
  Http_headers.fold (fun s l acc ->
    let s = Http_headers.name_to_string s in
    (List.map (fun v -> (s,v)) l) @ acc) headers []

let extract_content frame =
  let header = extract_headers frame in
  match frame.frame_content with
  | None -> return (header, "")
  | Some content ->
    try_lwt
      let st = Ocsigen_stream.get content in
      lwt s = Ocsigen_stream.string_of_stream 15000 st in
      lwt _ = Ocsigen_stream.finalize content `Success in
      return (header, s)
    with exn ->
      lwt _ = Ocsigen_stream.finalize content `Failure in
      Lwt.fail exn

let extract_content_to_chan chan frame =
  let header = extract_headers frame  in
  match frame.frame_content with
    None -> return header
  | Some content ->
    let st = Ocsigen_stream.get content in
    let rec loop st =
      Ocsigen_stream.next st >>= fun step ->
      match step with
      | Ocsigen_stream.Cont (s,st) -> Lwt_io.write chan s >>= fun () -> loop st
      | Ocsigen_stream.Finished None -> Lwt.return_unit
      | Ocsigen_stream.Finished (Some st) -> loop st
    in
    try_lwt
      lwt _ = loop st in
      lwt _ = Ocsigen_stream.finalize content `Success in
      return header
    with exn ->
      lwt _ = Ocsigen_stream.finalize content `Failure in
      Lwt.fail exn

let call ?(headers=[]) ?(body=`None) ~http_method url =
  let (https, host, port, uri, _, _, _) = Ocsigen_lib.Url.parse url in
  let uri = match uri with (* WHY *)
    | "" -> "/"
    | s when s.[0] <> '/' -> "/"^s
    | s -> s in
  let host = match host with None -> "localhost" | Some h -> h in
  Ocsigen_lib.Ip_address.get_inet_addr host >>= fun inet_addr ->
  let content = match body with
    | `None -> Lwt.return_none
    | `String s -> Lwt.return (Some (Ocsigen_stream.of_string s))
    | `InChannel (count,chan) ->
      let rec read c () =
        Lwt_io.read ~count:(min 1024 c) chan >>= fun s ->
        match String.length s with
        | 0 -> Ocsigen_stream.empty None
        | l ->
          let c = c-l in
          if c < 0
          then Ocsigen_stream.cont s (fun () -> Ocsigen_stream.empty None)
          else Ocsigen_stream.cont s (read c)
      in
      return (Some (Ocsigen_stream.make (read count)))
  in
  let content_length = match body with
    | `None -> None
    | `String s -> Some (Int64.of_int (String.length s))
    | `InChannel (count,_) -> Some (Int64.of_int count) in
  let headers = match content_length with
    | Some l ->
      let headers = ("Content-Length",Int64.to_string l)::(List.remove_assoc "Content-Length" headers) in
      if List.mem_assoc "Content-Type" headers
      then headers
      else ("Content-Type","application/x-www-form-urlencoded")::headers
    | _ -> headers in
  let headers =
    List.fold_left
      (fun h (n,v) ->
        Http_headers.add (Http_headers.name n) v h)
      Http_headers.empty headers
    in
  content >>= fun content ->
  Ocsigen_http_client.raw_request
    ?https
    ?port
    ~http_method:http_method
    ~content
    ?content_length
    ~headers
    ~host:(match port with None -> host | Some p -> host^":"^string_of_int p)
    ~inet_addr
    ~uri
    ()
    ()

let get ?headers url =
  call ?headers ~http_method:Ocsigen_http_frame.Http_header.GET url
  >>= extract_content

let get_to_chan ?headers url chan =
  call ?headers ~http_method:Ocsigen_http_frame.Http_header.GET url
  >>= extract_content_to_chan chan

let post ?headers ?(body=`None) url =
  call ?headers ~body ~http_method:Ocsigen_http_frame.Http_header.POST url
  >>= extract_content

let put ?headers ?(body=`None) url =
  call ?headers ~body ~http_method:Ocsigen_http_frame.Http_header.PUT url
  >>= extract_content

let delete ?headers url =
  call ?headers ~http_method:Ocsigen_http_frame.Http_header.DELETE url
  >>= extract_content

let head ?headers url =
  call ?headers ~http_method:Ocsigen_http_frame.Http_header.HEAD url
  >>= extract_content
