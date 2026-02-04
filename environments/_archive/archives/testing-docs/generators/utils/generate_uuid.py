import uuid

# make a UUID based on the host ID and current time
print(uuid.uuid1())


# make a UUID using an MD5 hash of a namespace UUID and a name
print(uuid.uuid3(uuid.NAMESPACE_DNS, 'python.org'))


# make a random UUID
print(uuid.uuid4())


# make a UUID using a SHA-1 hash of a namespace UUID and a name
print(uuid.uuid5(uuid.NAMESPACE_DNS, 'python.org'))


# make a UUID from a string of hex digits (braces and hyphens ignored)
x = uuid.UUID('{00010203-0405-0607-0809-0a0b0c0d0e0f}')
print(x)

# convert a UUID to a string of hex digits in standard form
str(x)



# get the raw 16 bytes of the UUID
x.bytes
print(x.bytes)


# make a UUID from a 16-byte string
uuid.UUID(bytes=x.bytes)
print(uuid.UUID(bytes=x.bytes))


# get the Nil UUID
uuid.NIL
print(uuid.NIL)


# get the Max UUID
uuid.MAX
print(uuid.MAX)


# same as UUIDv1 but with fields reordered to improve DB locality
uuid.uuid6()
print(uuid.uuid6())


# get UUIDv7 creation (local) time as a timestamp in milliseconds
u = uuid.uuid7()
print(u)
u.time
print(u.time / 1000)


# get UUIDv7 creation (local) time as a datetime object
import datetime as dt
dt.datetime.fromtimestamp(u.time / 1000)
print(dt.datetime.fromtimestamp(u.time / 1000))


# make a UUID with custom blocks
uuid.uuid8(0x12345678, 0x9abcdef0, 0x11223344)
print(uuid.uuid8(0x12345678, 0x9abcdef0, 0x11223344))