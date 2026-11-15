upstream =
  for name <- ~w(raise_pt402 raise_sqlstate_test1 raise_sqlstate_test2 raise_sqlstate_test3
                raise_sqlstate_test4 raise_sqlstate_invalid_json_message
                raise_sqlstate_invalid_json_details raise_sqlstate_missing_details) do
    %{id: "errors_custom/#{name}", path: "/rpc/#{name}", response_headers: ["x-header"]}
  end

probes =
  for {id, msg, det} <- [
        {"401-empty-headers", ~s|{"code":"123","message":"ABC"}|,
         ~s|{"status":401,"headers":{}}|},
        {"401-custom-headers", ~s|{"code":"123","message":"ABC"}|,
         ~s|{"status":401,"headers":{"X-Custom":"value"}}|},
        {"payment-header",
         ~s|{"code":"123","message":"Payment Required","details":"Quota exceeded","hint":"Upgrade your plan"}|,
         ~s|{"status":402,"headers":{"X-Powered-By":"Nerd Rage"}}|},
        {"missing-headers", ~s|{"code":"123","message":"ABC"}|, ~s|{"status":402}|},
        {"null-headers", ~s|{"code":"123","message":"ABC"}|, ~s|{"status":402,"headers":null}|},
        {"numeric-code", ~s|{"code":123,"message":"ABC"}|, ~s|{"status":402,"headers":{}}|},
        {"bad-details-type", ~s|{"code":"123","message":"ABC","details":{}}|,
         ~s|{"status":402,"headers":{}}|},
        {"bad-header-type", ~s|{"code":"123","message":"ABC"}|,
         ~s|{"status":402,"headers":{"X-Test":1}}|}
      ] do
    %{
      id: "errors_custom/#{id}",
      method: "POST",
      path: "/rpc/raise_payload",
      body: %{"msg" => msg, "det" => det},
      response_headers: ["x-powered-by", "www-authenticate", "x-custom"]
    }
  end

states =
  for state <- ~w(42P17 54001 PT699) do
    %{id: "errors_custom/state-#{state}", path: "/rpc/raise_state?state=#{state}"}
  end

upstream ++
  probes ++
  states ++
  [
    %{
      id: "errors_custom/content-type-header",
      method: "POST",
      path: "/rpc/raise_payload",
      body: %{
        "msg" => ~s|{"code":"123","message":"ABC"}|,
        "det" => ~s|{"status":402,"headers":{"Content-Type":"application/problem+json"}}|
      },
      only: :pgrest,
      expect: %{
        status: 402,
        headers: %{"content-type" => "application/problem+json"},
        body: %{"code" => "123", "message" => "ABC", "details" => nil, "hint" => nil}
      }
    }
  ]
