/*
  Copyright (C) 2006-2021 Inverse inc.

  This file is part of SOGo

  SOGo is free software; you can redistribute it and/or modify it under
  the terms of the GNU Lesser General Public License as published by the
  Free Software Foundation; either version 2, or (at your option) any
  later version.

  SOGo is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
  License for more details.

  You should have received a copy of the GNU Lesser General Public
  License along with SOGo; see the file COPYING.  If not, write to the
  Free Software Foundation, 59 Temple Place - Suite 330, Boston, MA
  02111-1307, USA.
*/

/*
  UIxMailListActions
  
  This component represent a list of mails and is attached to an SOGoMailFolder
  object.
*/

#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSCalendarDate.h>
#import <Foundation/NSCharacterSet.h>
#import <Foundation/NSTimeZone.h>
#import <Foundation/NSUserDefaults.h> /* for locale string constants */
#import <Foundation/NSValue.h>
#import <Foundation/NSNumberFormatter.h>

#import <NGObjWeb/WOApplication.h>
#import <NGObjWeb/WOContext+SoObjects.h>
#import <NGObjWeb/WORequest.h>
#import <NGObjWeb/SoObject+SoDAV.h>
#import <NGObjWeb/NSException+HTTP.h>
#import <NGExtensions/NSNull+misc.h>
#import <NGExtensions/NSString+misc.h>
#import <NGExtensions/NSObject+Logs.h>
#import <NGImap4/NGImap4Connection.h>
#import <NGImap4/NGImap4Envelope.h>

#import <EOControl/EOQualifier.h>

#import <Mailer/NSString+Mail.h>
#import <Mailer/SOGoDraftsFolder.h>
#import <Mailer/SOGoMailAccount.h>
#import <Mailer/SOGoSentFolder.h>
#import <Mailer/SOGoMailBodyPart.h>
#import <SOGo/NSArray+Utilities.h>
#import <SOGo/NSDictionary+Utilities.h>
#import <SOGo/NSObject+Utilities.h>
#import <SOGo/NSString+Utilities.h>
#import <SOGo/SOGoDateFormatter.h>
#import <SOGo/SOGoUser.h>
#import <SOGo/SOGoUserDefaults.h>
#import <SOGo/SOGoUserSettings.h>
#import <SOGo/WOResourceManager+SOGo.h>

#import <UI/MailPartViewers/UIxMailSizeFormatter.h>

#import "WOContext+UIxMailer.h"
#import "UIxMailFormatter.h"

#import "UIxMailListActions.h"

@class SOGoImageMailBodyPart;

// The maximum number of headers to prefetch when querying the UIDs list
#define headersPrefetchMaxSize 100

@implementation UIxMailListActions

- (id) initWithRequest: (WORequest *) newRequest
{
  SOGoUser *user;

  if ((self = [super initWithRequest: newRequest]))
    {
      user = [[self context] activeUser];
      ASSIGN (now, [NSCalendarDate calendarDate]);
      ASSIGN (dateFormatter, [user dateFormatterInContext: context]);
      ASSIGN (userTimeZone, [[user userDefaults] timeZone]);
      [now setTimeZone: userTimeZone];
      sortByThread = [[user userDefaults] mailSortByThreads];
      folderType = 0;
      specificMessageNumber = 0;
    }

  return self;
}

- (void) dealloc 
{
  [sortedUIDs release];
  [messages release];
  [message release];
  [dateFormatter release];
  [userTimeZone release];
  [super dealloc];
}

/* accessors */

- (void) setMessage: (id) _msg
{
  ASSIGN (message, _msg);
}

- (id) message 
{
  return message;
}

- (NSString *) messageDate
{
  NSCalendarDate *messageDate;

  messageDate = [[message valueForKey: @"envelope"] date];
  [messageDate setTimeZone: userTimeZone];

  if ([now dayOfCommonEra] == [messageDate dayOfCommonEra])
    {
      // Same day
      return [dateFormatter formattedTime: messageDate];
    }
  else if ([now dayOfCommonEra] - [messageDate dayOfCommonEra] == 1)
    {
      // Yesterday
      return [NSString stringWithFormat: @"%@ %@",
                      [self labelForKey: @"Yesterday" inContext: context],
                       [dateFormatter formattedTime: messageDate]];
    }
  else if ([now dayOfCommonEra] - [messageDate dayOfCommonEra] < 7)
    {
      // Same week
      return [NSString stringWithFormat: @"%@ %@",
                  [[locale objectForKey: NSWeekDayNameArray] objectAtIndex: [messageDate dayOfWeek]],
                       [dateFormatter formattedTime: messageDate]];
    }
  else
    {
      return [dateFormatter shortFormattedDate: messageDate];
    }
}

- (UIxMailSizeFormatter *) sizeFormatter
{
  return [UIxMailSizeFormatter sharedMailSizeFormatter];
}

//
// Priorities are defined like this:
//
// X-Priority: 1 (Highest)
// X-Priority: 2 (High)
// X-Priority: 3 (Normal)
// X-Priority: 4 (Low)
// X-Priority: 5 (Lowest)
//
// Sometimes, the MUAs don't send over the string in () so we ignore it.
//
- (NSDictionary *) messagePriority
{
  NSUInteger priority;
  NSString *description;
  NSData *data;
    
  data = [message objectForKey: @"header"];
  priority = 3;
  description = [self labelForKey: @"normal" inContext: context];

  if (data)
    {
      NSString *s;
      
      s = [[NSString alloc] initWithData: data
			    encoding: NSASCIIStringEncoding];

      if (s)
	{
	  NSRange r;

	  [s autorelease];
	  r = [s rangeOfString: @":"];

	  if (r.length)
	    {
	      s = [[s substringFromIndex: r.location+1]
		    stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];

	      if ([s hasPrefix: @"1"])
                {
                  priority = 1;
                  description = [self labelForKey: @"highest" inContext: context];
                }
	      else if ([s hasPrefix: @"2"])
                {
                  priority = 2;
                  description = [self labelForKey: @"high" inContext: context];
                }
	      else if ([s hasPrefix: @"4"])
                {
                  priority = 4;
                  description = [self labelForKey: @"low" inContext: context];
                }
	      else if ([s hasPrefix: @"5"])
                {
                  priority = 5;
                  description = [self labelForKey: @"lowest" inContext: context];
                }
	    }
	}
    }
  
  return [NSDictionary dictionaryWithObjectsAndKeys:
                            [NSNumber numberWithInt: priority], @"level",
                       description, @"name",
                       nil];
}

- (NSString *) messageSubject
{
  id baseSubject;
  NSString *subject;

  baseSubject = [[message valueForKey: @"envelope"] subject];
  subject = [baseSubject decodedHeader];
  if (![subject length])
    subject = @"";

  return subject;
}

- (BOOL) showToAddress
{
  SOGoMailFolder *co;

  if (!folderType)
    {
      co = [self clientObject];
      if ([co isKindOfClass: [SOGoSentFolder class]]
	  || [co isKindOfClass: [SOGoDraftsFolder class]])
	folderType = 1;
      else
	folderType = -1;
    }

  return (folderType == 1);
}

/* title */

- (NSString *) objectTitle 
{
  return [[self clientObject] nameInContainer];
}

- (NSString *) panelTitle 
{
  NSString *s;
  
  s = [self labelForKey:@"View Mail Folder" inContext: context];
  s = [s stringByAppendingString:@": "];
  s = [s stringByAppendingString:[self objectTitle]];
  return s;
}

/* derived accessors */

- (BOOL) isMessageDeleted
{
  NSArray *flags;
  
  flags = [[self message] valueForKey: @"flags"];
  return [flags containsObject: @"deleted"];
}

- (BOOL) isMessageRead
{
  NSArray *flags;
  
  flags = [[self message] valueForKey: @"flags"];
  return [flags containsObject: @"seen"];
}

- (BOOL) isMessageFlagged
{
  NSArray *flags;

  flags = [[self message] valueForKey: @"flags"];
  return [flags containsObject: @"flagged"];
}

- (BOOL) isMessageAnswered
{
  NSArray *flags;

  flags = [[self message] valueForKey: @"flags"];
  return [flags containsObject: @"answered"];
}

- (BOOL) isMessageForwarded
{
  NSArray *flags;

  flags = [[self message] valueForKey: @"flags"];
  return [flags containsObject: @"$forwarded"];
}

- (NSString *) messageUidString 
{
  return [[[self message] valueForKey:@"uid"] stringValue];
}

- (BOOL) parseParts: (NSArray *) parts hasAttachment:(BOOL) hasAttachment {
  NSEnumerator *part;
  NSDictionary *currentPart;
  SOGoUserDefaults *ud;
  BOOL isInline, isImage;
  NSString *contentType;

  ud = [[[self context] activeUser] userDefaults];
  
  if ([parts count] > 0)
    {
      part = [parts objectEnumerator];
      while (!hasAttachment
       && (currentPart = [part nextObject])) {
          if ([currentPart objectForKey: @"type"] && ![[[currentPart objectForKey: @"type"] uppercaseString] hasPrefix: @"MULTIPART"]) {
            contentType = [NSString stringWithFormat: @"%@/%@",
                          [currentPart objectForKey: @"type"],
                          [currentPart objectForKey: @"subtype"]];

            isInline = currentPart && [currentPart objectForKey:@"disposition"] 
                          && [[currentPart objectForKey:@"disposition"] objectForKey:@"type"] 
                          && [[[[currentPart objectForKey:@"disposition"] objectForKey:@"type"] uppercaseString] isEqualToString:@"INLINE"];
            isImage = [SOGoMailBodyPart bodyPartClassForMimeType: [contentType lowercaseString] inContext: [self context]] == [SOGoImageMailBodyPart class];
            

            if (![ud hideInlineAttachments] || ([ud hideInlineAttachments] && !(isInline && isImage))) {
              hasAttachment = ((([currentPart objectForKey:@"disposition"] 
                                && [[[currentPart objectForKey:@"disposition"] allKeys] length] > 0)
                                || ([currentPart objectForKey:@"parameterList"]
                                  && [[currentPart objectForKey:@"parameterList"] objectForKey:@"name"]
                                ))
                                && !(isInline && contentType && [[contentType lowercaseString] isEqualToString:@"text/plain"])
                                && !(isInline && contentType && [[contentType lowercaseString] isEqualToString:@"text/html"]));
            }
          } else if ([currentPart objectForKey:@"parts"]) {
            hasAttachment = [self parseParts: [currentPart objectForKey:@"parts"] hasAttachment: hasAttachment];
          }

          if (hasAttachment)
            break;
       }
    }

  return hasAttachment;
}

- (BOOL) hasMessageAttachment 
{
  BOOL hasAttachment;

  hasAttachment = NO;

  NS_DURING
  {
  hasAttachment = [self parseParts: [[message objectForKey: @"bodystructure"] objectForKey: @"parts"] hasAttachment:hasAttachment];
  }  
  NS_HANDLER
  {
    [self logWithFormat: @"Error while parsing attachements for rendering bracket"];
  }
  NS_ENDHANDLER;

  return hasAttachment;
}

/* fetching messages */

- (NSArray *) fetchKeys 
{
  /* Note: see SOGoMailManager.m for allowed IMAP4 keys */
  static NSArray *keys = nil;

  if (!keys)
    keys = [[NSArray alloc] initWithObjects: @"UID",
    			    @"FLAGS", @"ENVELOPE", @"RFC822.SIZE",
    			    @"BODYSTRUCTURE", @"BODY.PEEK[HEADER.FIELDS (X-PRIORITY)]", nil];
  return keys;
}

- (NSString *) defaultSortKey
{
  return @"ARRIVAL";
}

- (NSString *) imap4SortOrdering 
{
  WORequest *request;
  NSString *sort, *module;
  NSMutableDictionary *moduleSettings;
  NSDictionary *urlParams, *sortingAttributes;
  SOGoUser *activeUser;
  SOGoUserSettings *us;
  BOOL asc, dry;

  request = [context request];
  urlParams = [[request contentAsString] objectFromJSONString];
  sortingAttributes = [urlParams objectForKey: @"sortingAttributes"];
  sort = [[sortingAttributes objectForKey: @"sort"] uppercaseString];
  asc = [[sortingAttributes objectForKey: @"asc"] boolValue];
  dry = [[sortingAttributes objectForKey: @"dry"] boolValue];

  activeUser = [context activeUser];
  module = @"Mail";
  us = [activeUser userSettings];
  moduleSettings = [us objectForKey: module];

  if ([sort length])
    {
      if ([sort isEqualToString: [self defaultSortKey]] && !asc)
	{
	  if (moduleSettings && !dry)
	    {
	      [moduleSettings removeObjectForKey: @"SortingState"];
	      [us synchronize];
	    }
	}
      else if (!dry)
	{
	  // Save the sorting state in the user settings
	  if (!moduleSettings)
	    {
	      moduleSettings = [NSMutableDictionary dictionary];
	      [us setObject: moduleSettings forKey: module];
	    }
	  [moduleSettings setObject: [NSArray arrayWithObjects: [sort lowercaseString], [NSString stringWithFormat: @"%d", (asc ? 1 : 0)], nil]
			     forKey: @"SortingState"];
	  [us synchronize];
	}
    }
  else if (moduleSettings)
    {
      NSArray *sortState = [moduleSettings objectForKey: @"SortingState"];
      if ([sortState count])
	{
	  sort = [[sortState objectAtIndex: 0] uppercaseString];
	  asc = [[sortState objectAtIndex: 1] boolValue];
	}
    }
  if (![sort length])
    sort = [self defaultSortKey];
  
  // Construct and return the final IMAP ordering constraint
  if (!asc)
    sort = [@"REVERSE " stringByAppendingString: sort];

  return sort;
}

- (NSString *)sanitizeFilterString:(NSString *)str
{
  return [str stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

- (EOQualifier *) searchQualifier
{
  EOQualifier *qualifier, *notDeleted, *searchQualifier;
  WORequest *request;
  NSDictionary *sortingAttributes, *content, *filter;
  NSArray *filters, *labels, *searchInputSplit, *flags;
  NSString *searchBy, *searchInput, *searchString, *match, *label, *operator, *sizeUnit, *dateFrom, *dateTo;
  NSMutableArray *qualifiers, *searchArray, *labelQualifiers;
  NSNumberFormatter *formatter;
  NSNumber *size;
  BOOL unseenOnly, flaggedOnly;
  int max, i, j;
  
  request = [context request];
  content = [[request contentAsString] objectFromJSONString];
  notDeleted = [EOQualifier qualifierWithQualifierFormat: @"(not (flags = %@))", @"deleted"];
  qualifiers = [NSMutableArray arrayWithObject: notDeleted];
  searchString = @"";
  match = nil;
  filters = [content objectForKey: @"filters"];
  labels = [content objectForKey: @"labels"];
  unseenOnly = [[content objectForKey: @"unseenOnly"] boolValue];
  flaggedOnly = [[content objectForKey: @"flaggedOnly"] boolValue];

  if (filters)
    {
      max = [filters count];
      if (max > 0) {
        searchArray = [NSMutableArray arrayWithCapacity: max];
        for (i = 0; i < max; i++)
        {
          filter = [filters objectAtIndex:i];
          searchBy = [self sanitizeFilterString: [filter objectForKey: @"searchBy"]];
          searchInput = [self sanitizeFilterString:[filter objectForKey: @"searchInput"]];
          
          if (searchBy && searchInput)
            {
              // Size
              if ([searchBy isEqualToString: @"size"]) {
                operator = [filter objectForKey: @"operator"];
                sizeUnit = [filter objectForKey: @"sizeUnit"];
                formatter = [[NSNumberFormatter alloc] init];
                formatter.numberStyle = NSNumberFormatterDecimalStyle;
                size = [formatter numberFromString: searchInput];
                [formatter release];
                if ([[sizeUnit lowercaseString] isEqualToString: @"kb"]) {
                  size = [NSNumber numberWithLongLong: [size longLongValue] * 1024];
                } else if ([[sizeUnit lowercaseString] isEqualToString: @"mb"]) {
                  size = [NSNumber numberWithLongLong: [size longLongValue]  * 1024 * 1024];
                } else if ([[sizeUnit lowercaseString] isEqualToString: @"gb"]) {
                  size = [NSNumber numberWithLongLong: [size longLongValue] * 1024 * 1024 * 1024];
                }
                
                searchString = [NSString stringWithFormat: @"(%@ %@ %@)", searchBy, operator, [size stringValue]];
              } else if ([searchBy isEqualToString: @"date"]) {
                // Date
                operator = [filter objectForKey: @"operator"];
                searchString = [NSString stringWithFormat: @"(%@ %@ (NSCalendarDate)\"%@\")", searchBy, operator, searchInput];
              } else if ([searchBy isEqualToString: @"date_between"]) {
                // Date between
                dateFrom = [filter objectForKey: @"dateFrom"];
                dateTo = [filter objectForKey: @"dateTo"];
                searchString = [NSString stringWithFormat: @"(date >= (NSCalendarDate)\"%@\" AND date <= (NSCalendarDate)\"%@\")", dateFrom, dateTo];
              } else if ([searchBy isEqualToString: @"attachment"]) {
                // Attachment
                searchString = [NSString stringWithFormat: @"(text = 'attachment;') AND (text = 'filename')"];
              } else if ([searchBy isEqualToString: @"favorite"]) {
                // Favorite
                flaggedOnly = YES;
              } else if ([searchBy isEqualToString: @"unseen"]) {
                // Unseen
                unseenOnly = YES;
              } else if ([searchBy isEqualToString: @"contains"]) {
                // Contains
                // Split on space to check each word
                searchInput = [searchInput stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
                searchInputSplit = [searchInput componentsSeparatedByString:@" "];
                if ([searchInputSplit count] > 1) {
                  searchString = @"(";
                  j = 0;
                  for (searchInput in searchInputSplit) {
                    if (j > 0) {
                      searchString = [NSString stringWithFormat: @"%@ OR", searchString];
                    }
                    
                    searchString = [NSString stringWithFormat: @"%@ (subject doesContain: '%@' OR body doesContain: '%@' OR text = 'filename=*%@*')", 
                    searchString, searchInput, searchInput, searchInput];
                    j++;
                  }
                  searchString = [NSString stringWithFormat: @"%@)", searchString];
                } else {
                  searchString = [NSString stringWithFormat: @"(subject doesContain: '%@' OR body doesContain: '%@' OR text = 'filename=*%@*')", 
                    searchInput, searchInput, searchInput];
                }
              } else if ([searchBy isEqualToString: @"not_contains"]) {
                // Not contains
                searchInput = [searchInput stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
                searchString = [NSString stringWithFormat: @"(NOT (subject doesContain: '%@') AND NOT (body doesContain: '%@'))", 
                searchInput, searchInput];

                // Split on space to check each word
                searchInput = [searchInput stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
                searchInputSplit = [searchInput componentsSeparatedByString:@" "];
                if ([searchInputSplit count] > 1) {
                  searchString = @"(";
                  j = 0;
                  for (searchInput in searchInputSplit) {
                    if (j > 0) {
                      searchString = [NSString stringWithFormat: @"%@ AND", searchString];
                    }
                    
                    searchString = [NSString stringWithFormat: @"%@ (NOT (subject doesContain: '%@') AND NOT (body doesContain: '%@'))", 
                    searchString, searchInput, searchInput];
                    j++;
                  }
                  searchString = [NSString stringWithFormat: @"%@)", searchString];
                } else {
                  searchString = [NSString stringWithFormat: @"(NOT (subject doesContain: '%@') AND NOT (body doesContain: '%@'))", 
                    searchInput, searchInput];
                }
                } else if ([searchBy isEqualToString: @"flags"]) {
                // Flags
                flags = [filter objectForKey: @"flags"];
                if (flags && [flags count] > 0) {
                  searchString = @"(";
                  
                  for (j = 0 ; j < [flags count] ; j++) {
                    if (j > 0)
                      searchString = [NSString stringWithFormat: @"%@ AND", searchString];
                    searchString = [NSString stringWithFormat: @"%@ (flags = '%@')", 
                                      searchString, 
                                      [[flags objectAtIndex: j] stringByReplacingOccurrencesOfString: @"_$" withString:@"$"]];
                  }
                  searchString = [NSString stringWithFormat: @"%@)", searchString];
                }
              } else {
                // Others
                searchString = [NSString stringWithFormat: @"(%@ doesContain: '%@')", searchBy, searchInput];
              }

              if ([[filter objectForKey: @"negative"] boolValue])
                searchString = [NSString stringWithFormat: @"(not %@)", searchString];
              

              if (searchString && [searchString length] > 0) {
                searchQualifier = [EOQualifier qualifierWithQualifierFormat: searchString];
                if (searchQualifier)
                  [searchArray addObject: searchQualifier];
              }
            }
          else
            {
              [self errorWithFormat: @"Missing parameters in search filter: %@", filter];
            }
        }

        if ([searchArray count] > 0) {
          sortingAttributes = [content objectForKey: @"sortingAttributes"];
          if (sortingAttributes)
            match = [sortingAttributes objectForKey: @"match"]; // AND, OR
          if ([match isEqualToString: @"OR"])
            qualifier = [[EOOrQualifier alloc] initWithQualifierArray: searchArray];
          else
            qualifier = [[EOAndQualifier alloc] initWithQualifierArray: searchArray];
          [qualifier autorelease];
          [qualifiers addObject: qualifier];
        }
      }
    }

  if (unseenOnly)
    {
      searchQualifier = [EOQualifier qualifierWithQualifierFormat: @"(not (flags = %@))", @"seen"];
      [qualifiers addObject: searchQualifier];
    }
  if (flaggedOnly)
    {
      searchQualifier = [EOQualifier qualifierWithQualifierFormat: @"(flags = %@)", @"flagged"];
      [qualifiers addObject: searchQualifier];
    }
  if (labels)
    {
      max = [labels count];
      if (max > 0)
        {
          labelQualifiers = [NSMutableArray arrayWithCapacity: max];
            for (i = 0; i < max; i++)
            {
              label = [labels objectAtIndex: i];
              qualifier = [EOQualifier qualifierWithQualifierFormat: @"(flags = %@)", label];
              [labelQualifiers addObject: qualifier];
            }
            if (max > 1)
              {
                qualifier = [[EOOrQualifier alloc] initWithQualifierArray: labelQualifiers];
                [qualifier autorelease];
              }
            [qualifiers addObject: qualifier];
        }
    }

  if ([qualifiers count] > 1)
    {
      qualifier = [[EOAndQualifier alloc] initWithQualifierArray: qualifiers];
      [qualifier autorelease];
    }
  else
    qualifier = notDeleted;

  return qualifier;
}

- (NSArray *) getSortedUIDsInFolder: (SOGoMailFolder *) mailFolder
{
  if (!sortedUIDs)
    {
      sortedUIDs = [mailFolder fetchUIDsMatchingQualifier: [self searchQualifier]
                                             sortOrdering: [self imap4SortOrdering]
                                                 threaded: sortByThread];
      [sortedUIDs retain];
    }

  return sortedUIDs;
}

/**
 * Returns the messages threads as triples of
 * metadata, including the message UID, thread level and root position.
 * @param _sortedUIDs the interleaved arrays representation of the messages UIDs
 * @return an flatten array representation of the messages UIDs
 */
- (NSArray *) threadedUIDs: (NSArray *) _sortedUIDs
{
  NSMutableArray *threads;
  NSMutableArray *currentThreads;
  NSEnumerator *rootThreads;
  id thread;
  int count;
  int i;
  BOOL first;
  BOOL expected;

  i = 0;
  expected = YES;
  threads = [NSMutableArray arrayWithObject: [NSArray arrayWithObjects: @"uid", @"level", @"first", nil]];
  rootThreads  = [_sortedUIDs objectEnumerator];
  thread = [rootThreads nextObject];

  // Make sure rootThreads starts with an NSArray
  if (![thread respondsToSelector: @selector(objectEnumerator)])
    return nil;

  count = 0;
  first = [thread count] > 1;
  thread = [thread objectEnumerator];

  currentThreads = [NSMutableArray array];

  while (thread)
    {
      unsigned int ecount = 0;
      id t;

      if ([thread isKindOfClass: [NSEnumerator class]])
        {
          t = [thread nextObject];
        }
      else
        t = thread; // never happen?
      while (t && ![t isKindOfClass: [NSArray class]])
        {
          int level;
          NSArray *currentThread;

          level = first? 0 : (count > 0? count : -1);
          currentThread = [NSArray arrayWithObjects: t,
                            [NSNumber numberWithInt: level],
                            [NSNumber numberWithInt: first], nil];
          [threads addObject: currentThread];
          i++;
          count++;
          ecount++;
          expected = NO;
          t = [thread nextObject];
          first = 0;
        }
      if (t)
        {
          // If t is defined, it has to be an NSArray
          if (expected)
            {
              count++;
              expected = NO;
            }
          thread = [thread allObjects];
          if ([thread count] > 0)
            [currentThreads addObject: [thread objectEnumerator]];
          thread = [t objectEnumerator];
        }
      else if ([currentThreads count] > 0)
        {
          thread = [currentThreads objectAtIndex: 0];
          [currentThreads removeObjectAtIndex: 0];
          count -= ecount;
        }
      else
        {
          thread = [rootThreads nextObject];
          count = 0;
          first = [thread count] > 1;
          thread = [thread objectEnumerator];
          expected = YES;
        }

      // Prepare next iteration
      thread = [thread allObjects];
      thread = [thread objectEnumerator];
    }

  return threads;
}

- (int) indexOfMessageUID: (int) messageNbr
{
  NSArray *messageNbrs;
  int index;

  messageNbrs = [self getSortedUIDsInFolder: [self clientObject]];
  index
    = [messageNbrs indexOfObject: [NSNumber numberWithInt: messageNbr]];
//   if (index < 0)
//     index = 0;

  return index;
}

/* error redirects */

/*
- (id) redirectToViewWithError: (id) _error 
{
  // TODO: DUP in UIxMailAccountView
  // TODO: improve, localize
  // TODO: there is a bug in the treeview which preserves the current URL for
  //       the active object (displaying the error again)
  id url;
  
  if (![_error isNotNull])
    return [self redirectToLocation:@"view"];
  
  if ([_error isKindOfClass:[NSException class]])
    _error = [_error reason];
  else if ([_error isKindOfClass:[NSString class]])
    _error = [_error stringValue];
  
  url = [_error stringByEscapingURL];
  url = [@"view?error=" stringByAppendingString:url];
  return [self redirectToLocation:url];
}
*/

- (NSDictionary *) getUIDsInFolder: (SOGoMailFolder *) folder
                       withHeaders: (BOOL) includeHeaders
{
  return [self getUIDsInFolder: folder
                   withHeaders: includeHeaders
               onlyAttachments: NO];
}

- (NSDictionary *) getUIDsInFolder: (SOGoMailFolder *) folder
                       withHeaders: (BOOL) includeHeaders
                   onlyAttachments: (BOOL) onlyAttachments
{
  NSArray *uids, *threadedUids, *headers;
  NSMutableDictionary *data;
  NSMutableArray *tmpHeaders, *tmpUids;
  NSNumber *uid;
  SOGoMailAccount *account;
  id quota;

  NSRange r;
  int count, i, j;

  data = [NSMutableDictionary dictionary];

  // TODO: we might want to flush the caches?
  //[folder flushMailCaches];
  [folder expungeLastMarkedFolder];

  // Retrieve messages UIDs using form parameters "sort" and "asc"
  uids = [self getSortedUIDsInFolder: folder];
  if (uids == nil)
    {
      [folder unsubscribe]; // Mailbox is possibly missing -- cleanup subscriptions
      return nil;
    }
  
  // We first make sure QRESYNC is enabled
  if (![[folder imap4Connection] enableExtensions: [NSArray arrayWithObject: @"QRESYNC"]])
    {
      NSString *tag = [folder davCollectionTag];
      if (![tag isEqualToString: @"-1"])
        {
          [data setObject: tag forKey: @"syncToken"];
        }
    }

  // Get rid of the extra parenthesis
   // uids = [[[[uids stringValue] stringByReplacingOccurrencesOfString:@"(" withString:@""] stringByReplacingOccurrencesOfString:@")" withString:@""] componentsSeparatedByString:@","];

  if (includeHeaders)
    {
      // Also retrieve the first headers, up to 'headersPrefetchMaxSize'
      NSArray *a;

      a = [uids flattenedArray];
      count = [a count];
      if (count > headersPrefetchMaxSize && !onlyAttachments) // Only attachment to get all messages
        count = headersPrefetchMaxSize;
      r = NSMakeRange(0, count);
      headers = [self getHeadersForUIDs: [a subarrayWithRange: r]
                               inFolder: folder];

      [data setObject: headers forKey: @"headers"];
    }

  if (sortByThread)
    {
      // Add threads information
      threadedUids = [self threadedUIDs: uids];
      if (threadedUids != nil)
        uids = threadedUids;
      else
        sortByThread = NO;
    }

  if (uids != nil)
    [data setObject: uids forKey: @"uids"];
  [data setObject: [NSNumber numberWithBool: sortByThread] forKey: @"threaded"];

  // We get the unseen count
  [data setObject: [NSNumber numberWithUnsignedInt: [folder unseenCount]]  forKey: @"unseenCount"];

  // We also return the inbox quota
  account = [folder mailAccountFolder];
  quota = [account getInboxQuota];
  if (quota != nil)
    [data setObject: quota forKey: @"quotas"];

  return data;
}

/* Module actions */

/**
 * @api {get} /so/:username/Mail/:accountId/:mailboxPath/view List messages UIDs
 * @apiVersion 1.0.0
 * @apiName GetMailUIDsList
 * @apiGroup Mail
 * @apiExample {curl} Example usage:
 *     curl -i http://localhost/SOGo/so/sogo1/Mail/0/folderINBOX/view
 *          -H 'Content-Type: application/json' \
 *          -d '{ "sortingAttributes": { "match": "AND", "asc": true, "sort": "subject" }, \
 *                "filters": [{ "searchBy": "subject", "searchInput": "foo" }] }'
 *
 * @apiParam {Object} [sortingAttributes]                    Sorting preferences
 * @apiParam {Boolean} [sortingAttributes.asc]               Descending sort when false. Defaults to true (ascending).
 * @apiParam {String} [sortingAttributes.sort]               Sort field. Either c_cn, c_mail, c_screenname, c_o, or c_telephonenumber.
 * @apiParam {String} [sortingAttributes.match]              Either OR or AND.
 * @apiParam {String} [sortingAttributes.noHeaders]          Don't send the headers if true. Defaults to false.
 * @apiParam {Object[]} [filters]                            The filters to apply.
 * @apiParam {String} filters.searchBy                       Field criteria. Either subject, from, to, cc, or body.
 * @apiParam {String} filters.searchInput                    String to match.
 * @apiParam {String} [filters.negative]                     Reverse the condition when true. Defaults to false.
 * @apiParam {Boolean} [unseenOnly]                          Filter out seen messages when true. Defaults to false.
 *
 * @apiSuccess (Success 200) {Number} threaded               1 if threading is enabled for the user.
 * @apiSuccess (Success 200) {Number} unseenCount            Number of unread messages
 * @apiSuccess (Success 200) {Number[]} uids                 List of uids matching the filters, in the requested order.
 * @apiSuccess (Success 200) {String[]} headers              The first entry are the fields names.
 * @apiSuccess (Success 200) {Object[]} headers.To           Recipients
 * @apiSuccess (Success 200) {String} headers.To.name        Recipient's name
 * @apiSuccess (Success 200) {String} headers.To.email       Recipient's email address
 * @apiSuccess (Success 200) {Number} headers.hasAttachment  1 when there is at least one attachment
 * @apiSuccess (Success 200) {Number} headers.isFlagged      1 if the message is flagged
 * @apiSuccess (Success 200) {String} headers.Subject        Subject
 * @apiSuccess (Success 200) {Object[]} headers.From         Senders
 * @apiSuccess (Success 200) {String} headers.From.name      Sender's name
 * @apiSuccess (Success 200) {String} headers.From.email     Sender's email address
 * @apiSuccess (Success 200) {Number} headers.isRead         1 if message is read
 * @apiSuccess (Success 200) {String} headers.Priority       Priority
 * @apiSuccess (Success 200) {String} headers.Priority.level Priority number
 * @apiSuccess (Success 200) {String} headers.Priority.name  Priority description
 * @apiSuccess (Success 200) {String} headers.RelativeDate   Message date relative to now
 * @apiSuccess (Success 200) {String} headers.Size           Formatted message size
 * @apiSuccess (Success 200) {String[]} headers.Flags        Flags, such as "answered" and "seen"
 * @apiSuccess (Success 200) {Number} headers.uid            Message UID
 * @apiSuccess (Success 200) {Object} [quotas]               Quota information
 * @apiSuccess (Success 200) {Number} [quotas.usedSpace]     Used space
 * @apiSuccess (Success 200) {Number} [quotas.maxQuota]      Mailbox maximum quota
 */
- (id <WOActionResults>) getUIDsAction
{
  BOOL noHeaders, onlyAttachments;
  NSDictionary *data, *requestContent, *filter;
  SOGoMailFolder *folder;
  WORequest *request;
  WOResponse *response;

  request = [context request];
  requestContent = [[request contentAsString] objectFromJSONString];

  folder = [self clientObject];
  
  noHeaders = [[[requestContent objectForKey: @"sortingAttributes"] objectForKey: @"noHeaders"] boolValue];
  
  if ([[folder nameInContainer] isEqualToString: @"folderOther_SP_Users"]) {
    // When the folder is folderOther_SP_Users (shared main folder), return no mailboxes
    return response = [self responseWithStatus: 200
                    andJSONRepresentation: [NSDictionary dictionaryWithObject: [NSArray array] forKey:@"mailboxes"]];
  }
  
  onlyAttachments = NO;
  if (requestContent 
      && [requestContent objectForKey: @"filters"]
      && [[requestContent objectForKey: @"filters"] count] > 0) {
        for (filter in [requestContent objectForKey: @"filters"]) {
          if ([filter objectForKey: @"searchBy"]
              && [[filter objectForKey: @"searchBy"] isEqualToString: @"attachment"])
              onlyAttachments = YES;
        }
  }
  data = [self getUIDsInFolder: folder
                   withHeaders: !noHeaders
               onlyAttachments: onlyAttachments];

  if (data != nil)
    response = [self responseWithStatus: 200 andJSONRepresentation: data];
  else if ([folder isSpecialFolder])
    {
      response = [self responseWithStatus: 204];
    }
  else
    {
      data = [NSDictionary dictionaryWithObjectsAndKeys:
                             @"An error occured while communicating with the mail server", @"message", nil];
      response = [self responseWithStatus: 500 /* Error */
                    andJSONRepresentation: data];
    }

  return response;
}

- (id <WOActionResults>) getChangesAction
{
  NSArray *changedMessages, *headers;
  NSDictionary *requestContent, *data, *changedMessage;
  NSMutableArray *changedUids, *deletedUids;
  NSRange r;
  NSString *syncToken, *newSyncToken, *uid;
  SOGoMailFolder *folder;
  WORequest *request;
  WOResponse *response;
  int i, max;

  request = [context request];
  requestContent = [[request contentAsString] objectFromJSONString];
  response = nil;
  folder = [self clientObject];
  syncToken = [requestContent objectForKey: @"syncToken"];

  // We first make sure QRESYNC is enabled
  [[folder imap4Connection] enableExtensions: [NSArray arrayWithObject: @"QRESYNC"]];
  newSyncToken = [folder davCollectionTag];

  if ([syncToken length] && ![syncToken isEqual: newSyncToken])
    {
      // Fetch list of changed uids
      changedMessages = [folder syncTokenFieldsWithProperties: nil
                                            matchingSyncToken: syncToken
                                                     fromDate: nil
                                                  initialLoad: NO
                                                 sortOrdering: [self imap4SortOrdering]
                                                     threaded: sortByThread];
      if ((max = [changedMessages count]))
        {
          // Split new or modified uids from deleted uids
          changedUids = [NSMutableArray array];
          deletedUids = [NSMutableArray array];
          for (i = 0; i < max; i++)
            {
              changedMessage = [changedMessages objectAtIndex: i];
              uid = [[changedMessage allKeys] lastObject];
              if ([[changedMessage objectForKey: uid] isEqual: [NSNull null]])
                [deletedUids addObject: uid];
              else
                [changedUids addObject: uid];
            }

          // Fetch headers for new or modified messages
          max = [changedUids count];
          if (max > headersPrefetchMaxSize)
            max = headersPrefetchMaxSize;
          r = NSMakeRange(0, max);
          headers = [self getHeadersForUIDs: [changedUids subarrayWithRange: r]
                                   inFolder: folder];

          data = [NSDictionary dictionaryWithObjectsAndKeys:
                                 changedUids, @"changed",
                               deletedUids, @"deleted",
                               headers, @"headers",
                               newSyncToken, @"syncToken",
                               [NSNumber numberWithUnsignedInt: [folder unseenCount]], @"unseenCount",
                               nil];
          response = [self responseWithStatus: 200 andJSONRepresentation: data];
        }
    }
  if (!response)
    {
      data = [NSDictionary dictionaryWithObjectsAndKeys:
                           newSyncToken, @"syncToken",
                           nil];
      response = [self responseWithStatus: 200 andJSONRepresentation: data];
    }

  return response;
}

- (NSArray *) getHeadersForUIDs: (NSArray *) uids
		       inFolder: (SOGoMailFolder *) mailFolder
{
  UIxEnvelopeAddressFormatter *addressFormatter;
  NSAutoreleasePool *pool;
  NSMutableArray *headers, *msg, *tags;
  NSEnumerator *msgsList;
  NSArray *to, *from;
  NSDictionary *msgs;
  NSString *msgDate;
  int count;

  count = [uids count];
  headers = [NSMutableArray arrayWithCapacity: count];

  if (count > 0)
    {
      addressFormatter = [context mailEnvelopeAddressFormatter];

      // Fetch headers
      msgs = (NSDictionary *)[mailFolder fetchUIDs: uids
                                             parts: [self fetchKeys]];

      msgsList = [[msgs objectForKey: @"fetch"] objectEnumerator];
      [self setMessage: [msgsList nextObject]];

      msg = [NSMutableArray arrayWithObjects: @"To", @"hasAttachment", @"isFlagged", @"Subject", @"From", @"isRead", @"Priority", @"RelativeDate", @"Size", @"Flags", @"uid", @"isAnswered", @"isForwarded", nil];
      [headers addObject: msg];
      count = 0;
      pool = [[NSAutoreleasePool alloc] init];
      while (message)
        {
          // We must check for "umimportant" untagged responses.
          //
          // It's generally caused by IMAP server processes sending untagged IMAP responses to SOGo in differnent IMAP
          // connections (SOGo might use 2-3 per user). Say you ask your messages:
          //
          // 127.000.000.001.40725-127.000.000.001.00143: 59 uid fetch 62 (UID FLAGS ENVELOPE RFC822.SIZE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (X-PRIORITY)])
          // 127.000.000.001.00143-127.000.000.001.40725: * 62 FETCH (UID 62 FLAGS (\Seen) RFC822.SIZE 854 ENVELOPE  .... (
          // * 61 FETCH (FLAGS (\Deleted \Seen))
          // * 62 FETCH (FLAGS (\Deleted \Seen))
          // * 63 FETCH (FLAGS (\Deleted \Seen))
          // 59 OK Fetch completed.
          //
          // We must ignore the * 61 .. * 63 untagged responses.
          //
          if (![message objectForKey: @"uid"])
            {
              [self setMessage: [msgsList nextObject]];
              continue;
            }

          msg = [NSMutableArray arrayWithCapacity: 12];

          // Columns data

          // To
          to = [[message objectForKey: @"envelope"] to];
          if ([to count] > 0)
            [msg addObject: [addressFormatter dictionariesForArray: to]];
          else
            [msg addObject: @""];

          // hasAttachment
          [msg addObject: [NSNumber numberWithBool: [self hasMessageAttachment]]];

          // isFlagged
          [msg addObject: [NSNumber numberWithBool: [self isMessageFlagged]]];

          // Subject
          [msg addObject: [[self messageSubject] stringWithoutHTMLInjection: YES]];
      
          // From
          from = [[message objectForKey: @"envelope"] from];
          if ([from count] > 0)
            [msg addObject: [addressFormatter dictionariesForArray: from]];
          else
            [msg addObject: @""];
      
          // isRead
          [msg addObject: [NSNumber numberWithBool: [self isMessageRead]]];
      
          // Priority
          [msg addObject: [self messagePriority]];

          // Relative Date
          msgDate = [self messageDate];
          if (msgDate == nil)
            msgDate = @"";
          [msg addObject: msgDate];

          // Size
          [msg addObject: [[self sizeFormatter] stringForObjectValue: [message objectForKey: @"size"]]];

          // Mail labels / tags
          tags = [NSMutableArray arrayWithArray: [message objectForKey: @"flags"]];
          [tags removeObject: @"answered"];
          [tags removeObject: @"deleted"];
          [tags removeObject: @"draft"];
          [tags removeObject: @"flagged"];
          [tags removeObject: @"recent"];
          [tags removeObject: @"seen"];
          [tags removeObject: @"$forwarded"];
          [msg addObject: tags];

          // UID
          [msg addObject: [message objectForKey: @"uid"]];

          // isAnswered
          [msg addObject: [NSNumber numberWithBool: [self isMessageAnswered]]];

          // isForwarded
          [msg addObject: [NSNumber numberWithBool: [self isMessageForwarded]]];

          [headers addObject: msg];
      
          [self setMessage: [msgsList nextObject]];

          count++;
          if (count % 10 == 0)
            {
              [pool release];
              pool = [[NSAutoreleasePool alloc] init];
            }
        }
    }

  return headers;
}

- (id <WOActionResults>) getHeadersAction
{
  NSArray *uids, *headers;
  NSDictionary *data;
  WORequest *request;
  WOResponse *response;

  request = [context request];
  data = [[request contentAsString] objectFromJSONString];
  if (![[data objectForKey: @"uids"] isKindOfClass: [NSArray class]]
      || [[data objectForKey: @"uids"] count] == 0)
    {
      data = [NSDictionary dictionaryWithObjectsAndKeys:
                             @"No UID specified", @"message", nil];
      response = [self responseWithStatus: 404 /* Not Found */
                    andJSONRepresentation: data];

      return response;
    }

  uids = [data objectForKey: @"uids"];
  headers = [self getHeadersForUIDs: uids
			   inFolder: [self clientObject]];
  if (headers)
    response = [self responseWithStatus: 200
                  andJSONRepresentation: headers];
  else
    {
      data = [NSDictionary dictionaryWithObjectsAndKeys:
                             @"An error occured while communicating with the mail server", @"message", nil];
      response = [self responseWithStatus: 500 /* Error */
                    andJSONRepresentation: data];
    }

  return response;
}

@end

/* UIxMailListActions */
