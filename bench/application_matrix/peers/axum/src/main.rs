use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};

use axum::{
    Extension, Json, Router,
    extract::{Path, Query, State},
    http::{HeaderName, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::Response,
    routing::{get, post},
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct SmallDocument {
    id: i64,
    name: String,
    email: String,
    active: bool,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct MediumItem {
    id: i64,
    name: String,
    score: f64,
    active: bool,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct MediumDocument {
    request_id: String,
    items: Vec<MediumItem>,
    tags: Vec<String>,
}

#[derive(Serialize)]
struct RoutedResponse {
    id: i64,
    account_id: i64,
    verbose: bool,
}

#[derive(Deserialize)]
struct RoutedQuery {
    verbose: i64,
}

#[derive(Clone, Copy)]
struct AccountId(i64);

static REQUEST_ID: AtomicU64 = AtomicU64::new(0);

#[tokio::main]
async fn main() {
    let api = Router::new()
        .route("/users/{id}", get(routed_user))
        .layer(middleware::from_fn(auth))
        .layer(middleware::from_fn(noop))
        .layer(middleware::from_fn(noop))
        .layer(middleware::from_fn(request_id));

    let app = Router::new()
        .route("/health", get(health))
        .route("/json/small", get(json_small))
        .route("/json/medium", get(json_medium_get).post(json_medium))
        .route("/json/medium/decode", post(json_medium_decode))
        .route("/json/echo", post(json_echo))
        .nest("/api", api)
        .with_state(Arc::new(medium_document()));

    let port = std::env::args().nth(1).unwrap_or_else(|| "8081".to_owned());
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}"))
        .await
        .expect("bind benchmark listener");
    axum::serve(listener, app)
        .await
        .expect("serve benchmark listener");
}

async fn health() -> &'static str {
    "ok"
}

async fn json_small() -> Json<SmallDocument> {
    Json(SmallDocument {
        id: 42,
        name: "Ada".to_owned(),
        email: "ada@example.com".to_owned(),
        active: true,
    })
}

async fn json_medium_get(State(document): State<Arc<MediumDocument>>) -> Json<Arc<MediumDocument>> {
    Json(document)
}

async fn json_echo(Json(input): Json<SmallDocument>) -> Json<SmallDocument> {
    Json(input)
}

async fn json_medium(Json(input): Json<MediumDocument>) -> Json<MediumDocument> {
    Json(input)
}

async fn json_medium_decode(Json(_): Json<MediumDocument>) -> StatusCode {
    StatusCode::NO_CONTENT
}

async fn routed_user(
    Path(id): Path<i64>,
    Query(query): Query<RoutedQuery>,
    Extension(account): Extension<AccountId>,
) -> Json<RoutedResponse> {
    Json(RoutedResponse {
        id,
        account_id: account.0,
        verbose: query.verbose == 1,
    })
}

async fn request_id(request: axum::extract::Request, next: Next) -> Response {
    let id = REQUEST_ID.fetch_add(1, Ordering::Relaxed) + 1;
    let mut response = next.run(request).await;
    response.headers_mut().insert(
        HeaderName::from_static("x-request-id"),
        HeaderValue::from_str(&id.to_string()).expect("numeric request id"),
    );
    response
}

async fn noop(request: axum::extract::Request, next: Next) -> Response {
    next.run(request).await
}

async fn auth(mut request: axum::extract::Request, next: Next) -> Response {
    request.extensions_mut().insert(AccountId(7));
    next.run(request).await
}

fn medium_document() -> MediumDocument {
    let items = (1..=64)
        .map(|id| MediumItem {
            id,
            name: "item-abcdefghijklmnop".to_owned(),
            score: id as f64 + 0.5,
            active: true,
        })
        .collect();
    MediumDocument {
        request_id: "req-0123456789abcdef".to_owned(),
        items,
        tags: ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
    }
}
