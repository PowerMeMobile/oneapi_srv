%% Generated by the Erlang ASN.1 compiler version:1.6.18
%% Purpose: Erlang record definitions for each named and unnamed
%% SEQUENCE and SET, and macro definitions for each value
%% definition,in module JustAsn



-record('SmsRequest',{
id, gatewayId, customerId, type, message, encoding, params, sourceAddr, destAddrs, messageIds}).

-record('SmsResponse',{
id, gatewayId, customerId, statuses, timestamp}).

-record('IncomingSm',{
gatewayId, source, dest, message, dataCoding, partsRefNum = asn1_NOVALUE, partsCount = asn1_NOVALUE, partIndex = asn1_NOVALUE, timestamp}).

-record('ReceiptBatch',{
gatewayId, receipts, timestamp}).

-record('DeliveryReceipt',{
messageId, messageState, source}).

-record('FullAddr',{
addr, ton, npi}).

-record('FullAddrAndRefNum',{
fullAddr, refNum}).

-record('SmStatus',{
originalId, destAddr, status, partsTotal, partIndex = asn1_NOVALUE, messageId = asn1_NOVALUE, errorCode = asn1_NOVALUE}).

-record('Param',{
name, value}).

