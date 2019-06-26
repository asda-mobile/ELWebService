//
//  ServiceTask.swift
//  ELWebService
//
//  Created by Angelo Di Paolo on 2/25/15.
//  Copyright (c) 2015 WalmartLabs. All rights reserved.
//

import Foundation

/**
 A lightweight wrapper around `NSURLSessionDataTask` that provides a chainable
 API for processing the result of a data task. A `ServiceTask` instance can be
 cancelled and suspended like a data task as well as queried for current state
 via the `state` property.
*/
@objc public final class ServiceTask: NSObject {
    public typealias ResponseProcessingHandler = (Data?, URLResponse?) throws -> ServiceTaskResult
    
    /// A closure type alias for a success handler.
    public typealias UpdateUIHandler = (Any?) -> Void

    /// A closure type alias for an error handler.
    public typealias ErrorHandler = (Error) -> Void
    
    /// State of the service task.
    public var state: URLSessionTask.State {
        if let state = dataTask?.state {
            return state
        }
        
        return .suspended
    }
    
    /// Performance metrics collected during the execution of a service task
    public fileprivate(set) var metrics = ServiceTaskMetrics()
    
    fileprivate var request: Request

    /// A closure that will be used to asynchronously create the data for the request body.
    private var bodyProvider: AsyncDataProvider?

    fileprivate var urlRequest: URLRequest {
        return request.urlRequestValue as URLRequest
    }

    public var url: URL? {
        return urlRequest.url
    }
    
    /// Dispatch queue that queues up and dispatches handler blocks
    fileprivate let handlerQueue: OperationQueue
    
    /// Session data task that refers the lifetime of the request.
    fileprivate var dataTask: DataTask?
    
    /// Result of the service task
    fileprivate var taskResult: ServiceTaskResult? {
        didSet {
            // Use observer to watch for error result to send to passthrough
            guard let result = taskResult else { return }
            switch result {
            case .failure(let error):
                if responseError == nil {
                    passthroughDelegate?.serviceResultFailure(urlResponse, data: responseData, request: urlRequest, error: error)
                }
            case .empty, .value(_): return
            }
        }
    }
    
    /// Response body data
    fileprivate var responseData: Data?
    
    /// URL response
    fileprivate var urlResponse: URLResponse?
    
    fileprivate var responseError: Error?
    
    /// Type responsible for creating NSURLSessionDataTask objects
    fileprivate var session: Session?
    
    fileprivate var json: Any?
    
    fileprivate var metricsHandler: MetricsHandler?
    
    fileprivate var hasEverBeenSuspended = false
    
    /// Delegate interface for handling raw response and request events
    internal weak var passthroughDelegate: ServicePassthroughDelegate?
    
    // MARK: Intialization
    
    /**
     Initialize a ServiceTask value to fulfill an HTTP request.
    
     - parameter urlRequestEncoder: Value responsible for encoding a NSURLRequest
       instance to send.
     - parameter dataTaskSource: Object responsible for creating a
       NSURLSessionDataTask used to send the NSURLRequset.
    */
    init(request: Request, session: Session) {
        self.request = request
        self.session = session
        self.handlerQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.isSuspended = true
            return queue
        }()
    }
    
    deinit {
        handlerQueue.cancelAllOperations()
    }
}

// MARK: - Request API

extension ServiceTask {
    
    /**
     Sets a boolean that indicates whether the receiver should use the default
     cookie handling for the request.
     
     - parameter handle: true if the receiver should use the default cookie
     handling for the request, false otherwise. The default is true.
     - returns: Self instance to support chaining.
     */
    @discardableResult public func setShouldHandleCookies(_ handle: Bool) -> Self {
        request.shouldHandleCookies = handle
        return self
    }
    
    /// TODO: Needs docs
    @discardableResult public func setParameters(_ parameters: [String: Any], encoding: Request.ParameterEncoding? = nil) -> Self {
        request.parameters = parameters
        request.parameterEncoding = encoding ?? .percent
        
        return self
    }

    @discardableResult public func setBody(_ data: Data) -> Self {
        request.body = data
        return self
    }

    /// Sets the `body` of the request to the provided `data` and the `Content-Type` header to `contentType`.
    ///
    /// - Parameters:
    ///   - data: A `Data` instance.
    ///   - contentType: The `Content-Type` header value describing the type of `data`.
    /// - Returns: `self`
    @discardableResult public func setBody(_ data: Data, contentType: String) -> Self {
        request.body = data
        request.contentType = contentType
        return self
    }

    /// TODO: Needs docs
    @discardableResult public func setJSON(_ json: Any) -> Self {
        request.contentType = Request.ContentType.json
        request.body = try? JSONSerialization.data(withJSONObject: json, options: JSONSerialization.WritingOptions(rawValue: 0))
        return self
    }

    /// Sets the `body` of the `Request` to the provided `json` data and the `Content-Type` header
    /// to `application/json`.
    ///
    /// - Parameter json: A `Data` instance containing JSON data.
    /// - Returns: `self`
    @discardableResult public func setJSONData(_ json: Data) -> Self {
        return setBody(json, contentType: Request.ContentType.json)
    }
    
    /// TODO: Needs docs
    @discardableResult public func setHeaders(_ headers: [String: String]) -> Self {
        request.headers = headers
        return self
    }
    
    /// TODO: Needs docs
    @discardableResult public func setHeaderValue(_ value: String, forName name: String) -> Self {
        request.headers[name] = value
        return self
    }
    
    /// TODO: Needs docs
    @discardableResult public func setCachePolicy(_ cachePolicy: NSURLRequest.CachePolicy) -> Self {
        request.cachePolicy = cachePolicy
        return self
    }
    
    /// TODO: Needs docs
    @discardableResult public func setParameterEncoding(_ encoding: Request.ParameterEncoding) -> Self {
        request.parameterEncoding = encoding
        return self
    }
    
    /// Sets the key/value pairs that will be encoded as the query in the URL.
    @discardableResult public func setQueryParameters(_ parameters: [String: Any]) -> Self {
        request.queryParameters = parameters
        return self
    }
    
    /**
     Sets the key/value pairs that will be encoded as the query in the URL.
     
     - parameter parameters: Query parameter data.
     - parameter handler: A callback that is invoked when the query parameters are encoded in the URL. Enables you to define custom encoding behavior.
     - returns: Self instance to support chaining.
    */
    @discardableResult public func setQueryParameters(_ parameters: [String: Any], encoder: @escaping QueryParameterEncoder) -> Self {
        setQueryParameters(parameters)
        request.queryParameterEncoder = encoder
        return self
    }
    
    /// Sets the key/value pairs that are encoded as form data in the request body.
    @discardableResult public func setFormParameters(_ parameters: [String: Any]) -> Self {
        request.formParameters = parameters
        return self
    }

    /// Sets the key/value pairs that are encoded as form data in the request body.
    @discardableResult public func setFormParametersAllowedCharacters(_ allowedCharacters: CharacterSet) -> Self {
        request.formParametersAllowedCharacters = allowedCharacters
        return self
    }
}

// MARK: - Async Request Body API

extension ServiceTask {
    /// Sets the `body` of the request to the result of calling the `provideBody` closure.
    ///
    /// When this task is resumed for the first time, the `provideBody` closure is invoked on the main thread.
    ///
    /// The `provideBody` closure receives a callback as its sole argument. The callback should be invoked with
    /// `.success(data)` when the data is available, or with `.failure(error)` if an error occurs. The callback may
    /// be invoked from any thread.
    ///
    /// If successful, the data is used for the body of the outgoing request. Otherwise, the error is propagated to
    /// the registered `responseError` handlers.
    ///
    /// - Parameters:
    ///   - provideBody: An `AsyncDataProvider` closure that produces the data for the request body.
    /// - Returns: `self`
    @discardableResult func setBody(_ provideBody: @escaping AsyncDataProvider) -> Self {
        self.bodyProvider = provideBody
        request.body = nil
        return self
    }

    /// Sets the `body` of the request to the result of calling the `provideBody` closure and sets the
    /// `Content-Type` header to `contentType`.
    ///
    /// When this task is resumed for the first time, the `provideBody` closure is invoked on the main thread.
    ///
    /// The `provideBody` closure receives a callback as its sole argument. The callback should be invoked with
    /// `.success(data)` when the data is available, or with `.failure(error)` if an error occurs. The callback may
    /// be invoked from any thread.
    ///
    /// If successful, the data is used for the body of the outgoing request. Otherwise, the error is propagated to
    /// the registered `responseError` handlers.
    ///
    /// - Parameters:
    ///   - provideBody: An `AsyncDataProvider` closure that produces the data for the request body.
    ///   - contentType: The `Content-Type` header value describing the type of `data`.
    /// - Returns: `self`
    @discardableResult func setBody(_ provideBody: @escaping AsyncDataProvider, contentType: String) -> Self {
        request.contentType = contentType
        return setBody(provideBody)
    }

    /// Sets the `body` of the request to the result of calling the `provideBody` closure and sets the
    /// `Content-Type` header to `application/json`.
    ///
    /// When this task is resumed for the first time, the `provideBody` closure is invoked on the main thread.
    ///
    /// The `provideBody` closure receives a callback as its sole argument. The callback should be invoked with
    /// `.success(data)` when the data is available, or with `.failure(error)` if an error occurs. The callback may
    /// be invoked from any thread.
    ///
    /// If successful, the data is used for the body of the outgoing request. Otherwise, the error is propagated to
    /// the registered `responseError` handlers.
    ///
    /// - Parameters:
    ///   - provideBody: An `AsyncDataProvider` closure that produces the data for the request body.
    ///   - contentType: The `Content-Type` header value describing the type of `data`.
    /// - Returns: `self`
    @discardableResult func setJSONData(_ provideBody: @escaping AsyncDataProvider) -> Self {
        return setBody(provideBody, contentType: Request.ContentType.json)
    }
}

extension ServiceTask {
    /// A closure that provides data for the request body that is intended to be run on a background thread.
    public typealias RequestBodyProvider = () throws -> Data

    /// Sets the `body` of the request to the result of calling the `bodyProvider` closure.
    ///
    /// When this task is resumed for the first time, the `bodyProvider` closure is invoked on a background thread.
    /// The resulting data is used as the body of the outgoing request. If the closure throws an error, the error is
    /// propagated to the registered `resoponseError` handlers.
    ///
    /// - Parameters:
    ///   - bodyProvider: A `RequestBodyProvider` closure that produces the data for the request body.
    /// - Returns: `self`
    @discardableResult public func setBody(_ provideBody: @escaping RequestBodyProvider) -> Self {
        return setBody(asyncify(provideBody))
    }

    /// Sets the `body` of the request to the result of calling the `provideBody` closure and sets the
    /// `Content-Type` header to `contentType`.
    ///
    /// When this task is resumed for the first time, the `provideBody` closure is invoked on a background thread.
    /// The resulting data is used as the body of the outgoing request. If the closure throws an error, the error is
    /// propagated to the registered `resoponseError` handlers.
    ///
    /// - Parameters:
    ///   - provideBody: A `RequestBodyProvider` closure that produces the data for the request body.
    ///   - contentType: The `Content-Type` header value describing the type of `data`.
    /// - Returns: `self`
    @discardableResult public func setBody(_ provideBody: @escaping RequestBodyProvider, contentType: String) -> Self {
        return setBody(asyncify(provideBody), contentType: contentType)
    }

    /// Sets the `body` of the request to the result of calling the `provideBody` closure and sets the
    /// `Content-Type` header to `application/json`.
    ///
    /// When this task is resumed for the first time, the `provideBody` closure is invoked on a background thread.
    /// The resulting data is used as the body of the outgoing request. If the closure throws an error, the error is
    /// propagated to the registered `resoponseError` handlers.
    ///
    /// - Parameters:
    ///   - provideBody: A `RequestBodyProvider` closure that produces the data for the request body.
    /// - Returns: `self`
    @discardableResult public func setJSONData(_ provideBody: @escaping RequestBodyProvider) -> Self {
        return setJSONData(asyncify(provideBody))
    }
}

/// Converts a `RequestBodyProvider` block into an `AsyncDataProvider` block.
private func asyncify(queue: DispatchQueue = .global(),
                      _ bodyProvider: @escaping ServiceTask.RequestBodyProvider) -> AsyncDataProvider {
    return { callback in
        queue.async {
            do {
                callback(.success(try bodyProvider()))
            } catch {
                callback(.failure(error))
            }
        }
    }
}

// MARK: - NSURLSesssionDataTask

extension ServiceTask {
    /// Resume the underlying data task.
    @discardableResult public func resume() -> Self {
        if dataTask == nil {
            if let bodyProvider = bodyProvider {
                self.bodyProvider = nil

                dataTask = AsyncDataTask(bodyProvider) { result in
                    switch result {
                    case .success(let body):
                        self.request.body = body
                        self.initSessionDataTask()
                        self.dataTask?.resume()
                    case .failure(let error):
                        self.handleResponse(nil, data: nil, error: error)
                    }
                }
            } else {
                initSessionDataTask()
            }
        }
        
        metrics.fetchStartDate = Date()
        dataTask?.resume()
        
        // run metrics handler at end of queue
        if !hasEverBeenSuspended {
            handlerQueue.addOperation {
                self.sendMetrics()
            }
        }
        
        return self
    }

    private func initSessionDataTask() {
        self.dataTask =  session?.dataTask(request: urlRequest) { data, response, error in
            self.handleResponse(response, data: data, error: error)
        }
    }

    /// Suspend the underlying data task.
    public func suspend() {
        hasEverBeenSuspended = true
        dataTask?.suspend()
    }
    
    /// Cancel the underlying data task.
    public func cancel() {
        dataTask?.cancel()
    }
    
    /// Handle the response and kick off the handler queue
    internal func handleResponse(_ response: URLResponse?, data: Data?, error: Error?) {
        metrics.responseEndDate = Date()
        urlResponse = response
        responseData = data
        responseError = error
        
        if let responseError = responseError {
            taskResult = ServiceTaskResult.failure(responseError)
        }

        do {
            try self.passthroughDelegate?.validateResponse(response, data: data, error: error)
        } catch let validationError {
            taskResult = ServiceTaskResult.failure(validationError)
        }
        
        handlerQueue.isSuspended = false
    }
}

// MARK: - Response API

extension ServiceTask {
    /// A closure type alias for a result transformation handler.
    public typealias ResultTransformer = (Any?) throws -> ServiceTaskResult

    /**
     Add a response handler to be called on background thread after a successful
     response has been received.
    
     - parameter handler: Response handler to execute upon receiving a response.
     - returns: Self instance to support chaining.
    */
    public func response(_ handler: @escaping ResponseProcessingHandler) -> Self {
        handlerQueue.addOperation {
            if let taskResult = self.taskResult {
                switch taskResult {
                case .failure(_): return // bail out to avoid next handler from running
                case .empty, .value(_): break
                }
            }
            
            do {
                self.taskResult = try handler(self.responseData, self.urlResponse)
            } catch let error {
                self.taskResult = .failure(error)
            }
        }

        return self
    }
    
    /**
     Add a response handler to transform a (non-error) result produced by an earlier
     response handler.

     The handler can return any type of service task result, `.Empty`, `.Value` or
     `.Failure`. The result is propagated to later response handlers.

     - parameter handler: Transformation handler to execute.
     - returns: Self instance to support chaining.
     */
    public func transform(_ handler: @escaping ResultTransformer) -> Self {
        handlerQueue.addOperation {
            guard let taskResult = self.taskResult else {
                return
            }
            
            do {
                let resultValue = try taskResult.taskValue()
                self.taskResult = try handler(resultValue)
            } catch let error {
                self.taskResult = .failure(error)
            }
        }
        
        return self
    }

    /**
     Add a handler that runs on the main thread and is responsible for updating
     the UI with a given value. The handler is only called if a previous response
     handler in the chain does **not** return a `.Failure` value.
     
     If a response handler returns a value via ServiceTaskResult.Value the
     associated value will be passed to the update UI handler.
    
     - parameter handler: The closure to execute as the updateUI handler.
     - returns: Self instance to support chaining.
    */
    public func updateUI(_ handler: @escaping UpdateUIHandler) -> Self {
        handlerQueue.addOperation {
            guard let taskResult = self.taskResult else {
                return
            }
            
            do {
                let value = try taskResult.taskValue()
                
                DispatchQueue.main.sync {
                    self.passthroughDelegate?.updateUIBegin(self.urlResponse)
                    self.metrics.updateUIStartDate = Date()
                    handler(value)
                    self.metrics.updateUIEndDate = Date()
                    self.passthroughDelegate?.updateUIEnd(self.urlResponse)
                }
            } catch _ {
                return
            }
        }
        
        return self
    }
}

// MARK: - JSON

extension ServiceTask {
    /// A closure type alias for handling the response as JSON.
    public typealias JSONHandler = (Any, URLResponse?) throws -> ServiceTaskResult
    
    /**
     Add a response handler to serialize the response body as a JSON object. The
     handler will be dispatched to a background thread.
    
     - parameter handler: Response handler to execute upon receiving a response.
     - returns: Self instance to support chaining.
    */
    public func responseJSON(_ handler: @escaping JSONHandler) -> Self {
        return response { data, response in
            guard let data = data else {
                throw ServiceTaskError.jsonSerializationFailedNilResponseBody
            }
            
            if let json = self.json {
                return try handler(json, response)
            } else {
                self.metrics.responseJSONStartDate = Date()
                let json = try JSONSerialization.jsonObject(with: data, options: JSONSerialization.ReadingOptions.allowFragments)
                self.json = json
                let result = try handler(json, response)
                self.metrics.responseJSONEndDate = Date()
                return result
            }
        }
    }
}

// MARK: - Metrics

extension ServiceTask {
    public typealias MetricsHandler = (ServiceTaskMetrics, URLResponse?) -> Void
    
    /**
     Set a callback that will be invoked when service task metrics have been
     collected
     
     - parameter handler: Callback to invoke when metrics have been collected.
     - returns: Self instance to support chaining.
     */
    public func metricsCollected(_ handler: @escaping MetricsHandler) -> Self {
        metricsHandler = handler
        return self
    }
    
    func sendMetrics() {
        passthroughDelegate?.didFinishCollectingTaskMetrics(metrics: metrics, request: urlRequest, response: urlResponse, data: responseData, error: responseError)
        metricsHandler?(metrics, urlResponse)
    }
}

// MARK: - Error Handling

extension ServiceTask {
    /// A closure type alias for an error-recovery handler.
    public typealias ErrorRecoveryHandler = (Error) throws -> ServiceTaskResult

    /**
    Add a response handler to be called if a request results in an error.
    
    - parameter handler: Error handler to execute when an error occurs.
    - returns: Self instance to support chaining.
    */
    public func responseError(_ handler: @escaping ErrorHandler) -> Self {
        handlerQueue.addOperation {
            if let taskResult = self.taskResult {
                switch taskResult {
                case .failure(let error): handler(error)
                case .empty, .value(_): break
                }
            }
        }
        
        return self
    }
    
    /**
     Add a response handler to be called if a request results in an error. Handler
     will be called on the main thread.
     
     - parameter handler: Error handler to execute when an error occurs.
     - returns: Self instance to support chaining.
    */
    public func updateErrorUI(_ handler: @escaping ErrorHandler) -> Self {
        handlerQueue.addOperation {
            if let taskResult = self.taskResult {
                switch taskResult {
                case .failure(let error):
                    DispatchQueue.main.sync {
                        handler(error)
                    }
                case .empty, .value(_): break
                }
            }
        }
        
        return self
    }

    /**
     Add a response handler to recover from an error produced by an earlier response
     handler.
     
     The handler can return either a `.Value` or `.Empty`, indicating it was able to
     recover from the error, or an `.Failure`, indicating that it was not able to
     recover. The result is propagated to later response handlers.
     
     - parameter handler: Recovery handler to execute when an error occurs.
     - returns: Self instance to support chaining.
    */
    public func recover(_ handler: @escaping ErrorRecoveryHandler) -> Self {
        handlerQueue.addOperation {
            guard let taskResult = self.taskResult else {
                return
            }

            switch taskResult {
            case .failure(let error):
                do {
                    self.taskResult = try handler(error)
                } catch let error {
                    self.taskResult = .failure(error)
                }

            case .empty, .value(_):
                return // bail out; do not run this handler
            }
        }
        
        return self
    }
}

// MARK: - Errors

/// Errors that can occur when processing a response
public enum ServiceTaskError: Error {
    /// Failed to serialize a response body as JSON due to the data being nil.
    case jsonSerializationFailedNilResponseBody
}
